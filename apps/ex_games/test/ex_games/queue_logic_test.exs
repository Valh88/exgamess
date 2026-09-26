defmodule ExGames.QueueLogicTest do
  # Стратегия подбора ExGames.Matchmaking.PairsByRank как Room.Logic:
  # группировка по рангу, разброс, приоритет долгождавших, выход из очереди.

  use ExUnit.Case, async: false

  alias ExGames.Matchmaking.PairsByRank
  alias ExGames.Room.Server
  alias ExGames.Rooms
  alias ExGames.Test.FakeTransport
  alias ExGames.Wire

  setup do
    # матч-комната максимум на 4: 1 бронь создателя очереди + 2 участника группы
    target = "queue_target_#{System.unique_integer([:positive])}"
    :ok = ExGames.Matchmaker.define_room(target, ExGames.Test.LogicShell)

    {:ok, room_id} =
      Rooms.start(ExGames.Rooms.QueueRoom, options: %{"match_room_name" => target})

    {:ok, pid} = Rooms.lookup(room_id)

    %{room_id: room_id, room_pid: pid, target: target}
  end

  defp join!(room_id, rank) do
    sid = ExGames.Id.session_id()
    :ok = Server.reserve_seat(room_id, sid, %{"rank" => rank}, %{})
    {transport, _join, _state} = FakeTransport.attach!(room_id, sid)
    {sid, transport}
  end

  defp tick!(room_pid) do
    send(room_pid, :tick)

    # :sys message обрабатывается после :tick — гарантия, что тик отработал
    _ = :sys.get_state(room_pid)
    :ok
  end

  defp logic_state(room_pid) do
    server = :sys.get_state(room_pid)

    {_, state} = List.keyfind(server.logics, PairsByRank, 0)
    state
  end

  defp seat_frames(transport) do
    FakeTransport.frames(transport, 50)
    |> Enum.flat_map(fn frame ->
      case Wire.decode(frame) do
        {:ok, {:room_data, "seat", payload}} -> [payload]
        _ -> []
      end
    end)
  end

  # кадры пушатся асинхронными cast'ами — ждём их с ретраем
  defp eventual_seats(transport) do
    assert eventually(fn -> seat_frames(transport) != [] end)
    seat_frames(transport)
  end

  defp eventually(fun, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline,
        do: flunk("eventually condition not met")

      Process.sleep(10)
      do_eventually(fun, deadline)
    end
  end

  test "close ranks are grouped into a match", %{room_id: room_id, room_pid: pid} do
    {sid1, t1} = join!(room_id, 1000)
    {sid2, t2} = join!(room_id, 1050)

    tick!(pid)

    [seat1] = eventual_seats(t1)
    [seat2] = eventual_seats(t2)

    # оба в один матч, ранги эхом
    assert seat1["room_id"] == seat2["room_id"]
    assert seat1["session_id"] == sid1
    assert seat2["session_id"] == sid2
    assert seat1["rank"] == 1000
    assert seat2["rank"] == 1050

    # матч-комната реально создана и жива
    assert Rooms.alive?(seat1["room_id"])

    # очередь опустела
    assert logic_state(pid).waiting == %{}
  end

  test "rank gap keeps players waiting", %{room_id: room_id, room_pid: pid} do
    {sid1, t1} = join!(room_id, 1000)
    {sid2, _t2} = join!(room_id, 5000)

    tick!(pid)

    # никто не получил seat, оба в очереди
    assert seat_frames(t1) == []
    state = logic_state(pid)
    assert Map.has_key?(state.waiting, sid1)
    assert Map.has_key?(state.waiting, sid2)
  end

  test "priority after timeout overrides rank gap" do
    target = "queue_target_#{System.unique_integer([:positive])}"
    :ok = ExGames.Matchmaker.define_room(target, ExGames.Test.LogicShell)

    {:ok, room_id} =
      Rooms.start(
        ExGames.Rooms.QueueRoom,
        options: %{"match_room_name" => target, "priority_after_ms" => 0}
      )

    {:ok, pid} = Rooms.lookup(room_id)

    {_sid1, t1} = join!(room_id, 1000)
    {_sid2, t2} = join!(room_id, 5000)

    tick!(pid)

    assert [_] = eventual_seats(t1)
    assert [_] = eventual_seats(t2)
  end

  test "leaving the queue removes the player from matchmaking", %{room_id: room_id, room_pid: pid} do
    {sid1, t1} = join!(room_id, 1000)
    {sid2, t2} = join!(room_id, 1010)
    {sid3, t3} = join!(room_id, 1020)

    # sid3 уходит из очереди
    FakeTransport.send_frame(room_id, sid3, Wire.encode(:leave_room))

    assert eventually(fn ->
             MapSet.new(Map.keys(logic_state(pid).waiting)) == MapSet.new([sid1, sid2])
           end)

    tick!(pid)

    # матч собран из оставшихся двоих
    seats1 = eventual_seats(t1)
    seats2 = eventual_seats(t2)

    assert [%{"session_id" => ^sid1}] = seats1
    assert [%{"session_id" => ^sid2}] = seats2
    assert hd(seats1)["room_id"] == hd(seats2)["room_id"]

    for payload <- seat_frames(t3), do: flunk("leaver got a seat: #{inspect(payload)}")
  end
end
