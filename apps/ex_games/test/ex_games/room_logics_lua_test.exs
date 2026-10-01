defmodule ExGames.RoomLogicsLuaTest do
  # Тесты wildcard-диспетчеризации DSL и моста Room.Logics.Lua
  # (join/message/эффекты/устойчивость к ошибкам скрипта/мульти-Lua).

  use ExUnit.Case, async: false

  alias ExGames.GameLogic.Server, as: LogicServer
  alias ExGames.Room.Server
  alias ExGames.Rooms
  alias ExGames.Test.FakeTransport
  alias ExGames.Wire

  # -------------------------------------------------------------------------
  # Wildcard DSL (чистые Elixir-модули)
  # -------------------------------------------------------------------------

  defmodule Declared do
    use ExGames.Room.Logic

    @impl true
    def logic_init(_options, _room), do: {:ok, nil}

    message "known", payload, room, _client, state do
      IO.inspect({:declared_called, payload}, label: "DBG")
      broadcast(room, "declared", payload)
      {:ok, state}
    end
  end

  defmodule CatchAll do
    use ExGames.Room.Logic

    @impl true
    def logic_init(_options, _room), do: {:ok, nil}

    message :_, payload, room, _client, state do
      # фактический тип доступен в переменной `type`
      broadcast(room, "wildcard", %{"type" => type, "p" => payload})
      {:ok, state}
    end
  end

  defmodule WildcardRoom do
    use ExGames.Room, logic: [Declared, CatchAll]

    @impl true
    def room_init(_options, _room), do: {:ok, nil}
  end

  test "wildcard DSL: интроспекция модулей" do
    assert Declared.__message_types__() == ["known"]
    assert Declared.__message_wildcard__() == false
    assert CatchAll.__message_types__() == []
    assert CatchAll.__message_wildcard__() == true
  end

  test "wildcard DSL: объявленный тип — раньше wildcard'а" do
    {:ok, room_id} = Rooms.start(WildcardRoom)
    {sid, transport} = join!(room_id)

    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"known", %{"x" => 1}}))

    assert {:ok, {:room_data, "declared", %{"x" => 1}}} =
             Wire.decode(wait_for(transport, {:room_data, "declared"}))

    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"anything", %{"y" => 2}}))

    assert {:ok, {:room_data, "wildcard", %{"type" => "anything", "p" => %{"y" => 2}}}} =
             Wire.decode(wait_for(transport, {:room_data, "wildcard"}))

    Rooms.stop(room_id)
  end

  # -------------------------------------------------------------------------
  # Мост ExGames.Room.Logics.Lua (прямой режим, один скрипт)
  # -------------------------------------------------------------------------

  defmodule BridgeRoom do
    @lua Path.expand("../support/lua/greet.lua", __DIR__)

    use ExGames.Room,
      max_clients: 4,
      patch_rate: 60_000,
      logic: [ExGames.Room.Logics.Lua],
      lua_script: @lua

    @impl true
    def room_init(_options, _room), do: {:ok, nil}
  end

  test "мост: join → эффект broadcast + set_state" do
    {:ok, room_id} = Rooms.start(BridgeRoom)
    {sid, transport} = join!(room_id)

    assert {:ok, {:room_data, "joined", %{"sid" => ^sid}}} =
             Wire.decode(wait_for(transport, {:room_data, "joined"}))

    # состояние скрипта опубликовано через set_state
    assert eventually(fn ->
             case Server.state_snapshot(room_id) do
               {:ok, %{"players" => players}} -> map_size(players) == 1
               _ -> false
             end
           end)

    Rooms.stop(room_id)
  end

  test "мост: сообщение → эффект broadcast, состояние скрипта меняется" do
    {:ok, room_id} = Rooms.start(BridgeRoom)
    {sid1, t1} = join!(room_id)
    {_sid2, t2} = join!(room_id)

    FakeTransport.send_frame(room_id, sid1, Wire.encode(:room_data, {"greet", %{}}))

    assert {:ok, {:room_data, "greet", %{"from" => ^sid1, "total" => 1}}} =
             Wire.decode(wait_for(t1, {:room_data, "greet"}))

    assert {:ok, {:room_data, "greet", %{"total" => 1}}} =
             Wire.decode(wait_for(t2, {:room_data, "greet"}))

    assert eventually(fn ->
             match?({:ok, %{"greets" => 1}}, Server.state_snapshot(room_id))
           end)

    Rooms.stop(room_id)
  end

  test "мост: ошибка скрипта не роняет комнату" do
    {:ok, room_id} = Rooms.start(BridgeRoom)
    {sid, transport} = join!(room_id)
    wait_for(transport, {:room_data, "joined"})

    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"boom", %{}}))

    assert eventually(fn -> Rooms.alive?(room_id) end)

    # после ошибки скрипт продолжает работать (greet дожидается до ~1с —
    # этого достаточно, чтобы убедиться, что комната пережила ошибку)
    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"greet", %{}}))

    assert {:ok, {:room_data, "greet", _}} =
             Wire.decode(wait_for(transport, {:room_data, "greet"}))

    Rooms.stop(room_id)
  end

  test "мост: эффект kick выгоняет клиента" do
    {:ok, room_id} = Rooms.start(BridgeRoom)
    {_sid1, t1} = join!(room_id)
    {sid2, _t2} = join!(room_id)

    wait_for(t1, {:room_data, "joined"})

    FakeTransport.send_frame(room_id, sid2, Wire.encode(:room_data, {"kickme", %{}}))

    assert eventually(fn ->
             {:ok, listing} = Server.listing(room_id)
             listing.clients == 1
           end)

    assert eventually(fn ->
             sid2 not in Enum.map(clients_of(room_id), & &1.session_id)
           end)

    Rooms.stop(room_id)
  end

  test "мост: request \"schema\" возвращает M.schema" do
    {:ok, room_id} = Rooms.start(BridgeRoom)
    {sid, transport} = join!(room_id)
    wait_for(transport, {:room_data, "joined"})

    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_request, {42, "schema", %{}}))

    assert {:ok, {:room_response, 42, %{"messages" => messages, "state" => _}}} =
             Wire.decode(wait_for(transport, {:room_response, 42}))

    assert Enum.sort(messages) == ["boom", "corrupt", "greet", "kickme"]

    Rooms.stop(room_id)
  end

  test "мост: состояние вне схемы не публикуется, комната жива" do
    {:ok, room_id} = Rooms.start(BridgeRoom)
    {sid, transport} = join!(room_id)
    {_sid2, _t2} = join!(room_id)
    wait_for(transport, {:room_data, "joined"})

    # скрипт ломает players (map<number>) — превалидация моста пропускает
    # публикацию, но не эффекты и не комнату
    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"corrupt", %{}}))

    # маркер-эффект дошёл — решение о публикации к этому моменту принято
    assert {:ok, {:room_data, "corrupted", %{}}} =
             Wire.decode(wait_for(transport, {:room_data, "corrupted"}))

    # портящее состояние в комнату не ушло: players[sid] остался от join
    assert {:ok, %{"players" => %{^sid => 0}, "greets" => 0}} = Server.state_snapshot(room_id)

    # комната продолжает работать: kick выгоняет нарушителя, второй остаётся
    # (auto-dispose пустой комнаты не срабатывает)
    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"kickme", %{}}))

    assert eventually(fn ->
             {:ok, listing} = Server.listing(room_id)
             listing.clients == 1
           end)

    Rooms.stop(room_id)
  end

  test "гейт set_state: документ вне схемы отбрасывается, валидный применяется" do
    {:ok, room_id} = Rooms.start(BridgeRoom)
    {sid, transport} = join!(room_id)
    wait_for(transport, {:room_data, "joined"})

    assert {:ok, %{nil => schema}} = Server.state_schemas(room_id)
    assert schema["players"]["map"] == "number"

    handle = %ExGames.Room.Handle{room_id: room_id}

    ExGames.Room.set_state(handle, %{"players" => %{"x" => "wrong"}, "greets" => 1})

    # синхронизация: cast уже обработан (хелпер из гайдлайнов тестов)
    [{pid, _}] = Registry.lookup(ExGames.RoomRegistry, {:room, room_id})
    _ = :sys.get_state(pid)

    assert {:ok, %{"players" => %{^sid => 0}, "greets" => 0}} = Server.state_snapshot(room_id)

    ExGames.Room.set_state(handle, %{"players" => %{"x" => 5}, "greets" => 2})

    assert eventually(fn ->
             match?(
               {:ok, %{"players" => %{"x" => 5}, "greets" => 2}},
               Server.state_snapshot(room_id)
             )
           end)

    Rooms.stop(room_id)
  end

  test "мост: остановка комнаты останавливает LogicServer" do
    {:ok, room_id} = Rooms.start(BridgeRoom)
    {sid, _transport} = join!(room_id)
    _ = sid

    assert {:ok, _} = LogicServer.lookup(room_id)
    Rooms.stop(room_id)

    # Rooms.stop асинхронен (exit-сигнал): terminate → logic_terminate → stop
    assert eventually(fn -> LogicServer.lookup(room_id) == :error end)
  end

  # -------------------------------------------------------------------------
  # Мульти-Lua: типы из M.schema, свой VM на модуль, id {room_id, module}
  # -------------------------------------------------------------------------

  defmodule MultiLua.Physics do
    use ExGames.Room.Logics.Lua, script: Path.expand("../support/lua/ping.lua", __DIR__)
  end

  defmodule MultiLua.Economy do
    use ExGames.Room.Logics.Lua, script: Path.expand("../support/lua/hit.lua", __DIR__)
  end

  defmodule MultiLua.Room do
    use ExGames.Room, logic: [MultiLua.Physics, MultiLua.Economy]

    @impl true
    def room_init(_options, _room), do: {:ok, nil}
  end

  test "мульти-Lua: интроспекция из M.schema скриптов" do
    assert MultiLua.Physics.__message_types__() == ["ping"]
    assert MultiLua.Physics.__message_wildcard__() == false
    assert MultiLua.Economy.__message_types__() == ["hit"]
  end

  test "мульти-Lua: типы уходят в свои модули, id не коллидят" do
    {:ok, room_id} = Rooms.start(MultiLua.Room)
    {sid, transport} = join!(room_id)

    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"ping", %{}}))

    assert {:ok, {:room_data, "pong", %{"total" => 1}}} =
             Wire.decode(wait_for(transport, {:room_data, "pong"}))

    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"hit", %{}}))

    assert {:ok, {:room_data, "hit_seen", %{"total" => 1}}} =
             Wire.decode(wait_for(transport, {:room_data, "hit_seen"}))

    assert {:ok, _} = LogicServer.lookup({room_id, MultiLua.Physics})
    assert {:ok, _} = LogicServer.lookup({room_id, MultiLua.Economy})

    Rooms.stop(room_id)
  end

  # -------------------------------------------------------------------------
  # Haxe-скрипт (чанк `haxe -lua`) через мост — опция haxe: true
  # -------------------------------------------------------------------------

  defmodule HaxeRoom.HaxeLogic do
    use ExGames.Room.Logics.Lua,
      script: Path.expand("../support/lua/haxe_mlogic.lua", __DIR__),
      haxe: true
  end

  defmodule HaxeRoom.Game do
    use ExGames.Room, logic: [HaxeRoom.HaxeLogic]

    @impl true
    def room_init(_options, _room), do: {:ok, nil}
  end

  test "Haxe-скрипт в комнате: интроспекция из M.schema, join-эффект, сообщение" do
    # типы из M.schema Haxe-чанка (headless-прогон под шимами)
    assert HaxeRoom.HaxeLogic.__message_types__() == ["add"]
    assert HaxeRoom.HaxeLogic.__message_wildcard__() == false

    {:ok, room_id} = Rooms.start(HaxeRoom.Game)
    {sid, transport} = join!(room_id)

    # join-эффект из Haxe-логики
    assert {:ok, {:room_data, "haxe_joined", %{"sid" => ^sid}}} =
             Wire.decode(wait_for(transport, {:room_data, "haxe_joined"}))

    # сообщение → эффект из Haxe + state через set_state
    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"add", %{"n" => 2}}))

    assert {:ok, {:room_data, "added", %{"total" => 2}}} =
             Wire.decode(wait_for(transport, {:room_data, "added"}))

    assert eventually(fn ->
             match?(
               {:ok, %{"count" => 2, "joins" => %{^sid => true}}},
               Server.state_snapshot(room_id)
             )
           end)

    # request-поток через Haxe-чанк: значение-ответ (MLogic.call вернул
    # документ, а не массив эффектов)
    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_request, {11, "echo", %{"n" => 21}}))

    assert {:ok, {:room_response, 11, %{"to" => ^sid, "doubled" => 42}}} =
             Wire.decode(wait_for(transport, {:room_response, 11}))

    # request без обработчика в чанке — ошибка с request_id
    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_request, {12, "nope", %{}}))

    assert {:ok, {:error, %{"code" => 526, "message" => "unknown request", "request_id" => 12}}} =
             Wire.decode(wait_for(transport, :error))

    Rooms.stop(room_id)
  end

  # -------------------------------------------------------------------------
  # state_key: ветки общего состояния (мульти-модули не затирают друг друга)
  # -------------------------------------------------------------------------

  defmodule BranchLua.Physics do
    use ExGames.Room.Logics.Lua,
      script: Path.expand("../support/lua/ping.lua", __DIR__),
      state_key: "physics"
  end

  defmodule BranchLua.Economy do
    use ExGames.Room.Logics.Lua,
      script: Path.expand("../support/lua/hit.lua", __DIR__),
      state_key: "economy"
  end

  defmodule BranchLua.Room do
    use ExGames.Room, logic: [BranchLua.Physics, BranchLua.Economy]

    @impl true
    def room_init(_options, _room), do: {:ok, nil}
  end

  test "state_key: каждый модуль публикует в свою ветку game_state" do
    {:ok, room_id} = Rooms.start(BranchLua.Room)
    {sid, transport} = join!(room_id)

    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"ping", %{}}))
    assert {:ok, {:room_data, "pong", _}} = Wire.decode(wait_for(transport, {:room_data, "pong"}))

    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"hit", %{}}))

    assert {:ok, {:room_data, "hit_seen", _}} =
             Wire.decode(wait_for(transport, {:room_data, "hit_seen"}))

    # обе ветки живы одновременно — публикация одной не затёрла другую
    assert eventually(fn ->
             match?(
               {:ok, %{"physics" => %{"pings" => 1}, "economy" => %{"hits" => 1}}},
               Server.state_snapshot(room_id)
             )
           end)

    Rooms.stop(room_id)
  end

  test "state_key: карты схем по веткам, внешняя ветка вне схемы отбрасывается" do
    {:ok, room_id} = Rooms.start(BranchLua.Room)
    {sid, transport} = join!(room_id)

    assert {:ok, %{"physics" => physics_schema, "economy" => _}} =
             Server.state_schemas(room_id)

    assert physics_schema["pings"] == "number"

    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"ping", %{}}))
    assert {:ok, {:room_data, "pong", _}} = Wire.decode(wait_for(transport, {:room_data, "pong"}))

    handle = %ExGames.Room.Handle{room_id: room_id}

    ExGames.Room.set_state_branch(handle, "physics", %{"pings" => "not-a-number"})

    [{pid, _}] = Registry.lookup(ExGames.RoomRegistry, {:room, room_id})
    _ = :sys.get_state(pid)

    assert {:ok, %{"physics" => %{"pings" => 1}}} = Server.state_snapshot(room_id)

    Rooms.stop(room_id)
  end

  # -------------------------------------------------------------------------
  # Request-поток: wildcard-клейза моста → M.call("request", …)
  # -------------------------------------------------------------------------

  defmodule ReqLua.Logic do
    use ExGames.Room.Logics.Lua, script: Path.expand("../support/lua/request.lua", __DIR__)
  end

  defmodule ReqLua.Room do
    use ExGames.Room, logic: [ReqLua.Logic]

    @impl true
    def room_init(_options, _room), do: {:ok, nil}
  end

  test "request-поток: интроспекция wildcard'а у тонкого модуля" do
    assert ReqLua.Logic.__request_types__() == []
    assert ReqLua.Logic.__request_wildcard__() == true
  end

  test "мост: request через Lua-скрипт — значение-ответ клиенту" do
    {:ok, room_id} = Rooms.start(ReqLua.Room)
    {sid, transport} = join!(room_id)

    FakeTransport.send_frame(
      room_id,
      sid,
      Wire.encode(:room_request, {7, "answer", %{"q" => "hlt"}})
    )

    assert {:ok, {:room_response, 7, %{"to" => ^sid, "q" => "hlt", "n" => 1}}} =
             Wire.decode(wait_for(transport, {:room_response, 7}))

    # второй запрос — счётчик в state скрипта растёт
    FakeTransport.send_frame(
      room_id,
      sid,
      Wire.encode(:room_request, {8, "answer", %{"q" => "x"}})
    )

    assert {:ok, {:room_response, 8, %{"n" => 2}}} =
             Wire.decode(wait_for(transport, {:room_response, 8}))

    Rooms.stop(room_id)
  end

  test "мост: request без обработчика в скрипте — ошибка с request_id" do
    {:ok, room_id} = Rooms.start(ReqLua.Room)
    {sid, transport} = join!(room_id)

    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_request, {9, "nope", %{}}))

    assert {:ok, {:error, %{"code" => 526, "message" => "unknown request", "request_id" => 9}}} =
             Wire.decode(wait_for(transport, :error))

    Rooms.stop(room_id)
  end

  # -------------------------------------------------------------------------
  # Хелперы (по образцу room_lifecycle_test)
  # -------------------------------------------------------------------------

  defp join!(room_id) do
    sid = ExGames.Id.session_id()
    assert :ok = Server.reserve_seat(room_id, sid, %{}, %{})
    {transport, _join_frame, _state_frame} = FakeTransport.attach!(room_id, sid)
    {sid, transport}
  end

  defp clients_of(room_id) do
    {:ok, pid} = Rooms.lookup(room_id)
    %{clients: clients} = :sys.get_state(pid)
    Map.values(clients)
  end

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
