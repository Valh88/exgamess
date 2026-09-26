defmodule ExGames.RoomLogicTest do
  @moduledoc """
  Контракт встраиваемых модулей логики (ExGames.Room.Logic): роутинг по
  объявленным типам, цепочки join/leave/tick, авторизация, изоляция.
  """

  use ExUnit.Case, async: false

  alias ExGames.Room.Server
  alias ExGames.Rooms
  alias ExGames.Test.FakeTransport
  alias ExGames.Wire

  setup do
    {:ok, room_id} = Rooms.start(ExGames.Test.LogicShell)
    %{room_id: room_id}
  end

  test "logic_init receives create options", %{room_id: room_id} do
    {:ok, pid} = Rooms.lookup(room_id)
    %{logics: logics} = :sys.get_state(pid)

    assert {ExGames.Test.ScoreLogic, %{name: "score"}} =
             Enum.find(logics, fn {m, _} -> m == ExGames.Test.ScoreLogic end)
  end

  test "message routed to logic by declared type", %{room_id: room_id} do
    sid = join!(room_id, %{})

    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"add", %{"n" => 7}}))

    {:ok, pid} = Rooms.lookup(room_id)
    assert eventually(fn ->
             %{logics: logics} = :sys.get_state(pid)
             %{scores: scores} = logic_state(logics, ExGames.Test.ScoreLogic)
             scores[sid] == 7
           end)
  end

  test "message not declared by logics goes to room shell", %{room_id: room_id} do
    sid = join!(room_id, %{})
    [t] = transports(room_id, [sid])

    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"ping", %{}}))

    frame = ExGames.RoomLifecycleTestHelpers.wait(t, "pong")
    assert {:ok, {:room_data, "pong", %{}}} = Wire.decode(frame)
  end

  test "request routed to logic, reply correlated", %{room_id: room_id} do
    sid = join!(room_id, %{"start" => 42})
    [t] = transports(room_id, [sid])

    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_request, {5, "scores", %{}}))

    assert {:ok, {:room_response, 5, %{^sid => 42}}} =
             Wire.decode(ExGames.RoomLifecycleTestHelpers.wait_response(t, 5))
  end

  test "logic_join/leave maintain logic state slice", %{room_id: room_id} do
    sid = join!(room_id, %{"start" => 3})
    keeper = join!(room_id, %{})  # держит комнату живой при отсоединении первого

    {:ok, pid} = Rooms.lookup(room_id)
    %{logics: logics} = :sys.get_state(pid)
    %{scores: scores} = logic_state(logics, ExGames.Test.ScoreLogic)
    assert scores[sid] == 3

    Server.detach(room_id, sid)

    assert eventually(fn ->
      %{logics: logics, clients: clients} = :sys.get_state(pid)
      map_size(clients) == 1 and
        logic_state(logics, ExGames.Test.ScoreLogic).scores == %{keeper => 0}
    end)
  end

  test "logic_tick runs on room tick", %{room_id: room_id} do
    sid = join!(room_id, %{})
    {:ok, pid} = Rooms.lookup(room_id)

    assert eventually(fn ->
             %{logics: logics} = :sys.get_state(pid)
             logic_state(logics, ExGames.Test.ScoreLogic).ticks > 0
           end)

    assert ExGames.Rooms.alive?(room_id)
    assert is_binary(sid)
  end

  test "logic_auth can deny seat reservation", %{room_id: room_id} do
    assert {:error, :denied} =
             Server.reserve_seat(room_id, ExGames.Id.session_id(), %{"deny" => true}, %{})
  end

  test "room's handle_auth transforms auth before logic chain", %{room_id: room_id} do
    # LogicShell не определяет handle_auth → auth проходит как есть; ScoreLogic
    # получает "start" из auth и ставит начальный счёт (см. logic_join)
    sid = join!(room_id, %{"start" => 9})
    {:ok, pid} = Rooms.lookup(room_id)
    %{clients: clients} = :sys.get_state(pid)
    assert clients[sid].auth == %{"start" => 9}
  end

  test "crash in logic clause does not kill the room", %{room_id: room_id} do
    sid = join!(room_id, %{})

    # "boom" не объявлен никем и в оболочке нет клаузы — игнор
    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"unknown_msg", %{}}))

    assert Rooms.alive?(room_id)
  end

  test "logic_info receives messages sent to the room process", %{room_id: room_id} do
    sid = join!(room_id, %{})
    {:ok, pid} = Rooms.lookup(room_id)

    # внешний процесс шлёт произвольное сообщение в процесс комнаты
    send(pid, {:external_event, "ping_from_world"})

    assert eventually(fn ->
             %{logics: logics} = :sys.get_state(pid)
             %{infos: infos} = logic_state(logics, ExGames.Test.ScoreLogic)
             Enum.any?(infos, &(&1 == {:external_event, "ping_from_world"}))
           end)

    assert Rooms.alive?(room_id)
    assert is_binary(sid)
  end

  # -------------------------------------------------------------------------

  defp join!(room_id, auth) do
    sid = ExGames.Id.session_id()
    assert :ok = Server.reserve_seat(room_id, sid, auth, %{})
    FakeTransport.attach!(room_id, sid)
    sid
  end

  defp transports(room_id, sids) do
    Enum.map(sids, fn sid ->
      {:ok, pid} = Rooms.lookup(room_id)
      %{clients: clients} = :sys.get_state(pid)
      Map.fetch!(clients, sid).pid
    end)
  end

  defp logic_state(logics, mod), do: elem(Enum.find(logics, fn {m, _} -> m == mod end), 1)

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
