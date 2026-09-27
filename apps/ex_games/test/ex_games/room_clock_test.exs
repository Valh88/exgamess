defmodule ExGames.RoomClockTest do
  @moduledoc """
  Фаза 1 плана прод-минимума: Room clock (send_after/send_interval/cancel_timer)
  и auto_dispose_ms (льготное окно перед авто-закрытием пустой комнаты).
  """

  use ExUnit.Case, async: false

  alias ExGames.Room.Server
  alias ExGames.Rooms
  alias ExGames.Test.FakeTransport
  alias ExGames.Wire

  setup do
    {:ok, room_id} = Rooms.start(ExGames.Test.ClockRoom)
    %{room_id: room_id}
  end

  # -------------------------------------------------------------------------
  # Room clock
  # -------------------------------------------------------------------------

  test "send_after delivers {:ex_games_timer, key, msg} once", %{room_id: room_id} do
    {:ok, pid} = Rooms.lookup(room_id)
    handle = clock_handle(room_id)

    ExGames.Room.send_after(handle, :greet, "hello", 30)

    assert eventually(fn ->
             hits(:greet, pid) == ["hello"]
           end)

    # одноразовый: больше не приходит
    Process.sleep(60)
    assert hits(:greet, pid) == ["hello"]
  end

  test "send_after with the same key cancels the previous timer", %{room_id: room_id} do
    {:ok, pid} = Rooms.lookup(room_id)
    handle = clock_handle(room_id)

    ExGames.Room.send_after(handle, :k, "first", 30)
    ExGames.Room.send_after(handle, :k, "second", 30)

    assert eventually(fn -> hits(:k, pid) == ["second"] end)
    Process.sleep(60)
    assert hits(:k, pid) == ["second"]
  end

  test "send_interval fires repeatedly until cancelled", %{room_id: room_id} do
    {:ok, pid} = Rooms.lookup(room_id)
    handle = clock_handle(room_id)

    ExGames.Room.send_interval(handle, :beat, "tick", 40)

    assert eventually(fn -> length(hits(:beat, pid)) >= 3 end)

    ExGames.Room.cancel_timer(handle, :beat)

    before = length(hits(:beat, pid))
    Process.sleep(120)
    assert length(hits(:beat, pid)) == before
  end

  test "cancel_timer before the one-shot fires leaves no hit", %{room_id: room_id} do
    {:ok, pid} = Rooms.lookup(room_id)
    handle = clock_handle(room_id)

    ExGames.Room.send_after(handle, :late, "boom", 150)
    ExGames.Room.cancel_timer(handle, :late)

    Process.sleep(250)
    assert hits(:late, pid) == []
  end

  test "timers reach the logic chain (logic_info)", %{room_id: _room_id} do
    # ScoreLogic.logic_info собирает все не-служебные сообщения — таймер
    # обязан пройти через цепочку логик
    {:ok, room_id} = Rooms.start(ExGames.Test.LogicShell)
    {:ok, pid} = Rooms.lookup(room_id)

    ExGames.Room.send_interval(clock_handle(room_id), :logic_beat, "x", 30)

    assert eventually(fn ->
             %{logics: logics} = :sys.get_state(pid)
             {_mod, ls} = Enum.find(logics, fn {m, _} -> m == ExGames.Test.ScoreLogic end)

             Enum.any?(ls.infos, fn
               {:ex_games_timer, :logic_beat, "x"} -> true
               _ -> false
             end)
           end)

    GenServer.stop(pid, :normal)
  end

  test "dispose stops intervals without errors", %{room_id: room_id} do
    {:ok, pid} = Rooms.lookup(room_id)

    ExGames.Room.send_interval(clock_handle(room_id), :forever, "x", 30)
    assert eventually(fn -> length(hits(:forever, pid)) >= 1 end)

    GenServer.stop(pid, :normal)

    assert eventually(fn -> not Rooms.alive?(room_id) end)
  end

  # -------------------------------------------------------------------------
  # auto_dispose_ms
  # -------------------------------------------------------------------------

  test "auto_dispose_ms delays disposal after the last client leaves", %{room_id: _room_id} do
    {:ok, room_id} = Rooms.start(ExGames.Test.Room, auto_dispose_ms: 400)

    sid = ExGames.Id.session_id()
    assert :ok = Server.reserve_seat(room_id, sid, %{}, %{})
    {transport, _join, _state} = FakeTransport.attach!(room_id, sid)

    FakeTransport.send_frame(room_id, sid, Wire.encode(:leave_room))

    # клиент ушёл, но комната держится в льготном окне
    assert eventually(fn -> not Process.alive?(transport) end)
    assert Rooms.alive?(room_id)

    # ...и закрывается по таймеру
    assert eventually(fn -> not Rooms.alive?(room_id) end, 100)
  end

  test "auto_dispose_ms timer is cancelled by a new reservation and attach", %{room_id: _room_id} do
    {:ok, room_id} = Rooms.start(ExGames.Test.Room, auto_dispose_ms: 350)

    sid1 = ExGames.Id.session_id()
    assert :ok = Server.reserve_seat(room_id, sid1, %{}, %{})
    {t1, _join, _state} = FakeTransport.attach!(room_id, sid1)
    FakeTransport.send_frame(room_id, sid1, Wire.encode(:leave_room))
    assert eventually(fn -> not Process.alive?(t1) end)

    # в льготном окне приходит новый клиент — закрытие отменяется
    sid2 = ExGames.Id.session_id()
    assert :ok = Server.reserve_seat(room_id, sid2, %{}, %{})
    {t2, _join2, _state2} = FakeTransport.attach!(room_id, sid2)

    # переживаем исходное окно: комната жива и отвечает
    Process.sleep(500)
    assert Rooms.alive?(room_id)

    FakeTransport.send_frame(room_id, sid2, Wire.encode(:room_data, {"echo", %{"ok" => true}}))

    assert {:ok, {:room_data, "echo", %{"ok" => true}}} =
             Wire.decode(wait_for(t2, "echo"))

    {:ok, pid} = Rooms.lookup(room_id)
    GenServer.stop(pid, :normal)
  end

  test "empty room disposes immediately without auto_dispose_ms (default)", %{room_id: _room_id} do
    {:ok, room_id} = Rooms.start(ExGames.Test.Room)

    sid = ExGames.Id.session_id()
    assert :ok = Server.reserve_seat(room_id, sid, %{}, %{})
    {transport, _join, _state} = FakeTransport.attach!(room_id, sid)
    FakeTransport.send_frame(room_id, sid, Wire.encode(:leave_room))

    # дефолт (auto_dispose_ms: 0) — прежнее мгновенное поведение
    assert eventually(fn -> not Rooms.alive?(room_id) end)
    assert eventually(fn -> not Process.alive?(transport) end)
  end

  # -------------------------------------------------------------------------
  # Хелперы
  # -------------------------------------------------------------------------

  defp clock_handle(room_id), do: %ExGames.Room.Handle{room_id: room_id}

  defp hits(key, pid) do
    %{user_state: user_state} = :sys.get_state(pid)
    user_state.hits |> Enum.filter(fn {k, _} -> k == key end) |> Enum.map(fn {_, m} -> m end)
  end

  defp wait_for(transport, type, tries \\ 50)

  defp wait_for(_transport, _type, 0), do: raise("frame did not arrive in time")

  defp wait_for(transport, type, tries) do
    found =
      FakeTransport.frames(transport, 100)
      |> Enum.find(fn frame ->
        match?({:ok, {:room_data, t, _}} when t == type, Wire.decode(frame))
      end)

    if found do
      found
    else
      Process.sleep(20)
      wait_for(transport, type, tries - 1)
    end
  end

  defp eventually(fun, tries \\ 50)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, tries - 1)
    end
  end
end
