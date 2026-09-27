defmodule ExGames.RoomLifecycleTest do
  # Интеграционный тест жизненного цикла комнаты: брони, join, сообщения,
  # request/response, тик, авто-диспоуз. Использует реальное дерево
  # супервизии приложения (PubSub → Registry → RoomSupervisor).

  use ExUnit.Case, async: false

  alias ExGames.Room.Server
  alias ExGames.Rooms
  alias ExGames.Test.FakeTransport
  alias ExGames.Wire

  setup do
    {:ok, room_id} = Rooms.start(ExGames.Test.Room)
    %{room_id: room_id}
  end

  test "room starts and is discoverable", %{room_id: room_id} do
    assert Rooms.alive?(room_id)
    assert {:ok, listing} = Server.listing(room_id)
    assert listing.clients == 0
    assert listing.max_clients == 2
    assert listing.module == ExGames.Test.Room
  end

  test "two-phase join: reserve then attach", %{room_id: room_id} do
    sid = ExGames.Id.session_id()
    assert :ok = Server.reserve_seat(room_id, sid, %{"token" => "t"}, %{})

    # бронь видна в листинге
    assert {:ok, listing} = Server.listing(room_id)
    assert listing.clients == 1

    {transport, join_frame, _state_frame} = FakeTransport.attach!(room_id, sid)

    assert <<10, _::binary>> = join_frame

    assert {:ok, {:join_room, %{"room_id" => rid, "session_id" => ^sid}}} =
             Wire.decode(join_frame)

    assert rid == room_id

    # handle_join отработал: broadcast "join" ушёл транспорту (cast — асинхронный,
    # поэтому ждём кадр с поллингом)
    assert eventually(fn ->
             frames = FakeTransport.frames(transport, 100)

             Enum.any?(frames, fn frame ->
               match?({:ok, {:room_data, "join", _}}, Wire.decode(frame))
             end)
           end)

    frame = find_frame(transport, "join")

    assert {:ok, {:room_data, "join", %{"session_id" => ^sid, "auth" => auth}}} =
             Wire.decode(frame)

    assert auth == %{"token" => "t"}
  end

  test "attach without reservation fails", %{room_id: room_id} do
    sid = ExGames.Id.session_id()
    assert {:error, :no_reservation} = Server.attach(room_id, sid, self(), %{})
  end

  test "messages dispatch to DSL clauses; broadcast reaches everyone", %{room_id: room_id} do
    {sid1, sid2} = join_two!(room_id)
    [t1, t2] = transports(room_id, [sid1, sid2])

    frame = Wire.encode(:room_data, {"echo", %{"x" => 3}})
    FakeTransport.send_frame(room_id, sid1, frame)

    # оба получают broadcast "echo"
    assert {:ok, {:room_data, "echo", %{"x" => 3}}} =
             Wire.decode(wait_for(t1, {:room_data, "echo"}))

    assert {:ok, {:room_data, "echo", %{"x" => 3}}} =
             Wire.decode(wait_for(t2, {:room_data, "echo"}))

    request = Wire.encode(:room_request, {7, "whoami", %{}})
    FakeTransport.send_frame(room_id, sid2, request)

    assert {:ok, {:room_response, 7, %{"session_id" => ^sid2}}} =
             Wire.decode(wait_for(t2, {:room_response, 7}))
  end

  test "unknown request returns error frame", %{room_id: room_id} do
    {sid1, _} = join_two!(room_id)
    [t1] = transports(room_id, [sid1])

    FakeTransport.send_frame(room_id, sid1, Wire.encode(:room_request, {9, "nope", %{}}))

    assert {:ok, {:error, %{"code" => 526, "message" => "unknown request"}}} =
             Wire.decode(wait_for(t1, :error))
  end

  test "callback exception does not kill the room", %{room_id: room_id} do
    {sid1, _} = join_two!(room_id)
    [t1] = transports(room_id, [sid1])

    FakeTransport.send_frame(room_id, sid1, Wire.encode(:room_data, {"boom", %{}}))

    # комната жива, последующие сообщения работают
    assert Rooms.alive?(room_id)

    FakeTransport.send_frame(room_id, sid1, Wire.encode(:room_data, {"echo", %{"ok" => true}}))

    assert {:ok, {:room_data, "echo", %{"ok" => true}}} =
             Wire.decode(wait_for(t1, {:room_data, "echo"}))
  end

  test "max_clients=2 blocks the third reservation", %{room_id: room_id} do
    {sid1, sid2} = join_two!(room_id)
    assert is_binary(sid1) and is_binary(sid2)

    assert {:error, :full} = Server.reserve_seat(room_id, "third", %{}, %{})
  end

  test "expired seats free the slots", %{room_id: room_id} do
    # две краткие брони заполняют комнату (max_clients: 2)
    assert :ok = Server.reserve_seat(room_id, "ghost1", %{}, %{}, 40)
    assert :ok = Server.reserve_seat(room_id, "ghost2", %{}, %{}, 40)
    assert {:error, :full} = Server.reserve_seat(room_id, "third", %{}, %{})

    assert eventually(fn ->
             match?({:ok, %{clients: 0}}, Server.listing(room_id))
           end)

    # после истечения броней место снова доступно
    assert :ok = Server.reserve_seat(room_id, "later", %{}, %{})
  end

  test "leave_room frame triggers handle_leave and auto-dispose", %{room_id: room_id} do
    sid = ExGames.Id.session_id()
    Server.reserve_seat(room_id, sid, %{}, %{})
    {transport, _join, _state} = FakeTransport.attach!(room_id, sid)

    FakeTransport.send_frame(room_id, sid, Wire.encode(:leave_room))

    # комната опустела и закрылась (auto_dispose)
    assert eventually(fn -> not Rooms.alive?(room_id) end)
    # транспорт получил кадр закрытия и завершился
    assert eventually(fn -> not Process.alive?(transport) end)
  end

  test "tick runs at patch_rate and put_state broadcasts room_state", %{room_id: room_id} do
    sid = ExGames.Id.session_id()
    Server.reserve_seat(room_id, sid, %{}, %{})
    {transport, _join, _state} = FakeTransport.attach!(room_id, sid)
    {:ok, pid} = Rooms.lookup(room_id)

    :sys.replace_state(pid, fn state ->
      %{state | user_state: %{state.user_state | ticks: 100}}
    end)

    # set_state → на ближайшем тике комната разошлёт room_state
    GenServer.cast(pid, {:set_state, %{"ticks" => 100}})

    assert eventually(fn ->
             FakeTransport.frames(transport, 100)
             |> Enum.any?(fn f ->
               match?({:ok, {:room_state, %{"ticks" => 100}}}, Wire.decode(f))
             end)
           end)
  end

  test "delta mode: snapshot first, then patches, no empty frames", %{room_id: _room_id} do
    {:ok, room_id} = Rooms.start(ExGames.Test.Room, state_sync: :delta)
    {:ok, pid} = Rooms.lookup(room_id)

    sid = ExGames.Id.session_id()
    Server.reserve_seat(room_id, sid, %{}, %{})
    {transport, _join, _state} = FakeTransport.attach!(room_id, sid)

    # 1) первая доставка состояния — полный кадр
    GenServer.cast(pid, {:set_state, %{"a" => 1, "nested" => %{"x" => 0}}})

    assert eventually(fn ->
             FakeTransport.frames(transport, 100)
             |> Enum.any?(fn f ->
               match?({:ok, {:room_state, %{"a" => 1}}}, Wire.decode(f))
             end)
           end)

    # 2) изменение вложенного ключа → патч только по нему
    GenServer.cast(pid, {:set_state, %{"a" => 1, "nested" => %{"x" => 5}}})

    assert eventually(fn ->
             FakeTransport.frames(transport, 100)
             |> Enum.any?(fn f ->
               match?(
                 {:ok, {:room_state_patch, %{"ops" => [%{"p" => ["nested", "x"], "v" => 5}]}}},
                 Wire.decode(f)
               )
             end)
           end)

    # 3) повторная установка того же состояния → новых кадров нет
    before = length(FakeTransport.frames(transport, 100))
    GenServer.cast(pid, {:set_state, %{"a" => 1, "nested" => %{"x" => 5}}})
    Process.sleep(60)
    assert length(FakeTransport.frames(transport, 100)) == before

    # 4) новый клиент получает полный снапшот (не патч)
    sid2 = ExGames.Id.session_id()
    Server.reserve_seat(room_id, sid2, %{}, %{})
    {_t2, _join, snapshot} = FakeTransport.attach!(room_id, sid2)
    assert {:ok, {:room_state, %{"a" => 1, "nested" => %{"x" => 5}}}} = Wire.decode(snapshot)

    GenServer.stop(pid, :normal)
  end

  test "broadcast_except delivers to everyone except the excluded session", %{room_id: _room_id} do
    {:ok, room_id} = Rooms.start(ExGames.Test.ExceptRoom)

    sids = for _ <- 1..3, do: ExGames.Id.session_id()

    Enum.each(sids, fn sid ->
      assert :ok = Server.reserve_seat(room_id, sid, %{}, %{})
      FakeTransport.attach!(room_id, sid)
    end)

    [sender, lt1, lt2] = sids
    [ts1, ts2] = transports(room_id, [lt1, lt2])

    FakeTransport.send_frame(room_id, sender, Wire.encode(:room_data, {"say", %{"n" => 1}}))

    # слушатели получают
    assert {:ok, {:room_data, "say", %{"n" => 1}}} =
             Wire.decode(wait_for(ts1, {:room_data, "say"}))

    assert {:ok, {:room_data, "say", %{"n" => 1}}} =
             Wire.decode(wait_for(ts2, {:room_data, "say"}))

    # говорящий — нет
    [sender_t] = transports(room_id, [sender])

    refute Enum.any?(FakeTransport.frames(sender_t, 100), fn f ->
             match?({:ok, {:room_data, "say", _}}, Wire.decode(f))
           end)

    {:ok, pid} = Rooms.lookup(room_id)
    GenServer.stop(pid, :normal)
  end

  test "dispose closes clients with 4000", %{room_id: room_id} do
    sid = ExGames.Id.session_id()
    Server.reserve_seat(room_id, sid, %{}, %{})
    {transport, _join, _state} = FakeTransport.attach!(room_id, sid)

    Server.dispose(room_id)
    assert eventually(fn -> not Rooms.alive?(room_id) end)

    # транспорт получил закрытие (его процесс завершается по сообщению)
    assert eventually(fn -> not Process.alive?(transport) end)
  end

  test "kick removes client: room disposes (auto) and transport closes", %{room_id: room_id} do
    sid = ExGames.Id.session_id()
    Server.reserve_seat(room_id, sid, %{}, %{})
    {transport, _join, _state} = FakeTransport.attach!(room_id, sid)
    {:ok, pid} = Rooms.lookup(room_id)

    GenServer.cast(pid, {:kick, sid})

    # последний клиент вышел — комната закрылась (auto_dispose)
    assert eventually(fn -> not Rooms.alive?(room_id) end)
    assert eventually(fn -> not Process.alive?(transport) end)
  end

  # -------------------------------------------------------------------------
  # Хелперы
  # -------------------------------------------------------------------------

  defp join_two!(room_id) do
    sid1 = ExGames.Id.session_id()
    sid2 = ExGames.Id.session_id()
    assert :ok = Server.reserve_seat(room_id, sid1, %{}, %{})
    assert :ok = Server.reserve_seat(room_id, sid2, %{}, %{})
    FakeTransport.attach!(room_id, sid1)
    FakeTransport.attach!(room_id, sid2)
    {sid1, sid2}
  end

  defp transports(room_id, sids) do
    Enum.map(sids, fn sid ->
      {:ok, pid} = Rooms.lookup(room_id)

      # достаём pid транспорта из состояния комнаты (только для тестов)
      %{clients: clients} = :sys.get_state(pid)
      Map.fetch!(clients, sid).pid
    end)
  end

  # Ждёт кадр заданного типа (broadcast — async cast, кадры приходят с задержкой).
  defp wait_for(transport, kind, tries \\ 50)

  defp wait_for(_transport, _kind, 0), do: raise("frame did not arrive in time")

  defp wait_for(transport, kind, tries) do
    frames = FakeTransport.frames(transport, 100)

    case Enum.find(frames, fn frame -> frame_kind(frame) == kind end) do
      nil ->
        Process.sleep(20)
        wait_for(transport, kind, tries - 1)

      frame ->
        frame
    end
  end

  defp find_frame(transport, type) do
    frames = FakeTransport.frames(transport, 100)

    Enum.find(frames, fn frame ->
      match?({:ok, {:room_data, t, _}} when t == type, Wire.decode(frame))
    end) || flunk("no room_data #{inspect(type)} frame")
  end

  defp frame_kind(frame) do
    case Wire.decode(frame) do
      {:ok, {:room_data, type, _payload}} -> {:room_data, type}
      {:ok, {:room_response, request_id, _payload}} -> {:room_response, request_id}
      {:ok, {:error, _payload}} -> :error
      {:ok, {kind, _}} -> kind
      {:ok, {kind}} -> kind
      _ -> :invalid
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
