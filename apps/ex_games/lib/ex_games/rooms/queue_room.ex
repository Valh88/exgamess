defmodule ExGames.Rooms.QueueRoom do
  @moduledoc """
  Очередь подбора (аналог QueueRoom в Colyseus): игроки ждут, раз в тик
  сортируются по рангу, полные группы расформируются в игровую комнату.

  Опции комнаты (передаются в `room_init` через `options`):

    * `"match_room_name"` — тип игровой комнаты (обязателен);
    * `"group_size"` — размер группы (по умолчанию `2`);
    * `"max_rank_gap"` — максимальный разброс рангов внутри группы
      (по умолчанию `200`); группы из игроков с большим разбросом не
      собираются, пока ожидание < `"priority_after_ms"`;
    * `"priority_after_ms"` — после этого ожидания игрок получает приоритет
      и подбирается почти к любым рангам (по умолчанию `10_000`).

  Клиент кладёт ранг в опциях join: `%{"options" => %{"rank" => 1500}}`.

  Как только группа собрана: матчмейкер создаёт игровую комнату, всем
  участникам бронируются места, каждый получает сообщение
  `{"seat", reservation}` — и подключается по нему к игровой комнате.
  """

  use ExGames.Room, max_clients: :infinity, patch_rate: 1000, rate_limit: 120

  alias ExGames.Id
  alias ExGames.Matchmaker

  @impl true
  def room_init(options, _room) do
    {:ok,
     %{
       match_room_name: Map.get(options, "match_room_name"),
       group_size: Map.get(options, "group_size", 2),
       max_rank_gap: Map.get(options, "max_rank_gap", 200),
       priority_after_ms: Map.get(options, "priority_after_ms", 10_000),
       waiting: %{}
     }}
  end

  @impl true
  def handle_join(room, client, auth, state) do
    rank = rank_from(auth, client)

    broadcast(room, "queue_join", %{"session_id" => client.session_id, "rank" => rank})

    {:ok,
     Map.put(state, :waiting, Map.put(state.waiting, client.session_id, %{
       rank: rank,
       joined_at: System.monotonic_time(:millisecond)
     }))}
  end

  @impl true
  def handle_leave(_room, client, _reason, state) do
    {:ok, Map.put(state, :waiting, Map.delete(state.waiting, client.session_id))}
  end

  @impl true
  def handle_tick(_dt, state) do
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
  # Группировка: сортировка по рангу, скользящее окно на group_size,
  # допуск по разбросу рангов с приоритетом долгождавших.
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

        if Enum.max(ranks) - Enum.min(ranks) <= gap do
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

  defp rank_from(auth, client) do
    case auth do
      %{"rank" => rank} when is_integer(rank) -> rank
      %{"rank" => rank} when is_binary(rank) -> String.to_integer(rank)
      _ -> default_rank(client)
    end
  end

  defp default_rank(_client), do: 1000

  @doc false
  def generated_session, do: Id.session_id()
end
