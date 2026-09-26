defmodule ArenaExample.QueueRoom do
  @moduledoc """
  Демо-очередь 2×2: группы по 2 игрока подбираются по рангу; когда собрано
  2 группы, они играют вместе на арене на 4 человека (одна комната арены).

  Простой вариант поверх `ExGames.Rooms.QueueRoom`-подхода: своя логика
  группировки из двух групп.
  """

  use ExGames.Room, max_clients: :infinity, patch_rate: 1000, rate_limit: 120

  @group_size 2

  @impl true
  def room_init(_options, room) do
    {:ok, %{room: room, waiting: %{}}}
  end

  @impl true
  def handle_join(room, client, auth, state) do
    rank = rank(auth)

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

    # сортируем по рангу, собираем полные группы
    queue =
      state.waiting
      |> Enum.sort_by(fn {_sid, info} -> info.rank end)

    {groups, rest} = collect_groups(queue, @group_size, [])

    # каждая полная группа → своя арена: бронируем места и шлём "seat"
    Enum.each(groups, fn group -> match_group(state, group) end)

    {:ok, %{state | waiting: Map.new(rest)}}
  end

  defp match_group(state, group) do
    case ExGames.Matchmaker.create("arena", %{}, %{"mode" => "ranked"}) do
      {:ok, reservation} ->
        Enum.each(group, fn {sid, info} ->
          :ok = ExGames.Room.Server.reserve_seat(reservation.room_id, sid, %{}, %{})

          ExGames.Room.send_to(state.room, sid, "seat", %{
            "room_id" => reservation.room_id,
            "session_id" => sid,
            "rank" => info.rank
          })
        end)

        :telemetry.execute([:arena, :queue, :matched], %{count: length(group)}, %{
          room_id: reservation.room_id
        })

      {:error, reason} ->
        Enum.each(group, fn {sid, _} ->
          ExGames.Room.send_to(state.room, sid, "queue_error", %{"reason" => inspect(reason)})
        end)
    end

    :ok
  end

  defp collect_groups(queue, size, acc) do
    if length(queue) >= size do
      {group, rest} = Enum.split(queue, size)
      collect_groups(rest, size, [group | acc])
    else
      {Enum.reverse(acc), queue}
    end
  end

  defp rank(%{"rank" => rank}) when is_integer(rank), do: rank
  defp rank(%{"rank" => rank}) when is_binary(rank), do: String.to_integer(rank)
  defp rank(_), do: 1000
end
