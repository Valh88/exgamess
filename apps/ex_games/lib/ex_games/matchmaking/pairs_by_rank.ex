defmodule ExGames.Matchmaking.PairsByRank do
  @moduledoc """
  Стратегия подбора (`ExGames.Room.Logic`): игроки в очереди группируются
  по рангу, полные группы расформируются в игровую комнату.

  Встраивается в комнату-очередь (см. `ExGames.Rooms.QueueRoom`):

      use ExGames.Room, logic: [ExGames.Matchmaking.PairsByRank]

  Алгоритм: сортировка по рангу, скользящее окно на `group_size`; если
  разброс рангов в окне больше `max_rank_gap`, первый кандидат отпускается
  и окно сдвигается. Игрок, ожидавший дольше `priority_after_ms`, получает
  приоритет: он рассматривается первым и гэп по рангам для его группы
  не применяется.

  Собранная группа: матчмейкер создаёт игровую комнату, каждому участнику
  бронируется место, каждый получает сообщение `{"seat", reservation}` —
  и подключается по нему к игровой комнате.

  Опции комнаты (попадают в `logic_init` через `options`):

    * `"match_room_name"` — тип игровой комнаты (обязателен);
    * `"group_size"` — размер группы (по умолчанию `2`);
    * `"max_rank_gap"` — максимальный разброс рангов в группе (по умолчанию `200`);
    * `"priority_after_ms"` — ожидание до приоритета (по умолчанию `10_000`).

  Ранг игрок кладёт в опциях join: `%{"options" => %{"rank" => 1500}}`
  (через `logic_auth` он переезжает в auth); если сервер положил ранг
  в auth сам (например, рейтинг из БД) — клиентское значение игнорируется.

  Своя стратегия подбора — такой же модуль `ExGames.Room.Logic`
  (`logic_join` ставит в очередь, `logic_tick` собирает матчи).
  """

  use ExGames.Room.Logic

  alias ExGames.Matchmaker

  @impl true
  def logic_init(options, room) do
    {:ok,
     %{
       room: room,
       match_room_name: Map.get(options, "match_room_name"),
       group_size: Map.get(options, "group_size", 2),
       max_rank_gap: Map.get(options, "max_rank_gap", 200),
       priority_after_ms: Map.get(options, "priority_after_ms", 10_000),
       waiting: %{}
     }}
  end

  # Ранг приплывает в auth: либо сервер сам положил его туда (например,
  # рейтинг из БД при брони — клиент не может соврать), либо из опций join.
  # Серверное значение имеет приоритет над клиентским.
  @impl true
  def logic_auth(auth_data, options, _room) do
    auth = auth_data || %{}

    case auth do
      %{"rank" => _} ->
        {:ok, auth}

      _ ->
        {:ok, Map.put(auth, "rank", Map.get(options || %{}, "rank", 1000))}
    end
  end

  @impl true
  def logic_join(room, client, auth, state) do
    rank = rank_from(auth)

    broadcast(room, "queue_join", %{"session_id" => client.session_id, "rank" => rank})

    {:ok,
     Map.put(
       state,
       :waiting,
       Map.put(state.waiting, client.session_id, %{
         rank: rank,
         joined_at: System.monotonic_time(:millisecond)
       })
     )}
  end

  @impl true
  def logic_leave(_room, client, _reason, state) do
    {:ok, Map.put(state, :waiting, Map.delete(state.waiting, client.session_id))}
  end

  @impl true
  def logic_tick(_elapsed, state) do
    now = System.monotonic_time(:millisecond)

    waiting =
      state.waiting
      |> Map.new(fn {sid, info} -> {sid, Map.put(info, :waited_ms, now - info.joined_at)} end)

    state = %{state | waiting: waiting}
    {matched, waiting} = group(state, now)

    Enum.each(matched, fn group -> start_match(state, group) end)

    {:ok, %{state | waiting: waiting}}
  end

  # -------------------------------------------------------------------------
  # Группировка
  # -------------------------------------------------------------------------

  defp group(state, now) do
    entries =
      state.waiting
      |> Enum.map(fn {sid, info} ->
        priority? = now - info.joined_at >= state.priority_after_ms
        {sid, Map.put(info, :priority?, priority?)}
      end)
      |> Enum.sort_by(fn {_sid, info} -> {not info.priority?, info.rank} end)

    do_group(entries, state.group_size, state.max_rank_gap, [], [])
  end

  defp do_group([], _size, _gap, matched, left), do: {Enum.reverse(matched), Map.new(left)}

  defp do_group(entries, size, gap, matched, left) do
    case Enum.split(entries, size) do
      {candidates, rest} when length(candidates) == size ->
        ranks = Enum.map(candidates, fn {_, info} -> info.rank end)

        # приоритетному игроку гэп не применяется: его группа собирается
        # при любом разбросе
        gap_ok? =
          Enum.max(ranks) - Enum.min(ranks) <= gap or
            Enum.any?(candidates, fn {_, info} -> info.priority? end)

        if gap_ok? do
          do_group(rest, size, gap, [candidates | matched], left)
        else
          # окно не собирается: отпускаем первого кандидата, пробуем дальше
          [first | rest2] = entries
          do_group(rest2, size, gap, matched, [first | left])
        end

      {_short, _rest} ->
        do_group([], size, gap, matched, left ++ entries)
    end
  end

  defp start_match(state, group) do
    with {:ok, reservation} <-
           Matchmaker.create(state.match_room_name, %{}, %{}) do
      # первый участник уже имеет бронь (reserve при create); бронируем остальных
      Enum.each(group, fn {sid, _info} ->
        :ok = ExGames.Room.Server.reserve_seat(reservation.room_id, sid, %{}, %{})
      end)

      Enum.each(group, fn {sid, info} ->
        send_to(
          state.room,
          sid,
          "seat",
          %{
            "room_id" => reservation.room_id,
            "session_id" => sid,
            "rank" => info.rank
          }
        )
      end)

      :telemetry.execute([:ex_games, :queue, :matched], %{count: length(group)}, %{
        room_id: reservation.room_id
      })

      :ok
    else
      {:error, reason} ->
        # матчмейкер недоступен/тип не зарегистрирован: возвращаем игроков в очередь
        Enum.each(group, fn {sid, _info} ->
          send_to(state.room, sid, "queue_error", %{"reason" => inspect(reason)})
        end)

        :error
    end
  end

  defp rank_from(auth) do
    case auth do
      %{"rank" => rank} when is_integer(rank) -> rank
      %{"rank" => rank} when is_binary(rank) -> String.to_integer(rank)
      _ -> 1000
    end
  end
end
