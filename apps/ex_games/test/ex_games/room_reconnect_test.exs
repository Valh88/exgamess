defmodule ExGames.RoomReconnectTest do
  # Reconnection-токены: не-согласованный обрыв → слот reconnection → reattach.
  # Логики не получают join/leave повторно; срез состояния логики сохраняется.

  use ExUnit.Case, async: false

  alias ExGames.Room.Server
  alias ExGames.Rooms
  alias ExGames.Test.FakeTransport
  alias ExGames.Wire

  @ttl 150

  setup do
    {:ok, room_id} = Rooms.start(ExGames.Test.LogicShell, reconnect_ttl: @ttl)
    %{room_id: room_id}
  end

  defp join!(room_id) do
    sid = ExGames.Id.session_id()
    :ok = Server.reserve_seat(room_id, sid, %{}, %{})
    {transport, join_frame, _state_frame} = FakeTransport.attach!(room_id, sid)
    {:ok, {:join_room, payload}} = Wire.decode(join_frame)
    {transport, sid, payload}
  end

  # Убивает транспорт и ждёт, пока комната обработает DOWN (появится слот).
  # Транспорт слинкован с тестом — отвязываемся, чтобы :kill не убил тест.
  defp drop_and_await_slot!(room_id, sid, token, transport) do
    Process.unlink(transport)
    Process.exit(transport, :kill)

    assert eventually(fn ->
             match?({:ok, ^sid}, Server.reconnect(room_id, sid, token))
           end)
  end

  # Комната обработала все предыдущие cast'ы (гайдлайн тестов).
  defp sync_room!(room_id) do
    [{pid, _}] = Registry.lookup(ExGames.RoomRegistry, {:room, room_id})
    _ = :sys.get_state(pid)
    :ok
  end

  defp bump_score!(room_id, sid, n) do
    FakeTransport.send_frame(room_id, sid, Wire.encode(:room_data, {"add", %{"n" => n}}))
  end

  defp request_scores!(transport, room_id, sid, request_id) do
    FakeTransport.send_frame(
      room_id,
      sid,
      Wire.encode(:room_request, {request_id, "scores", %{}})
    )

    assert eventually(fn ->
             FakeTransport.frames(transport, 50)
             |> Enum.any?(fn frame ->
               match?({:ok, {:room_response, ^request_id, _}}, Wire.decode(frame))
             end)
           end)

    frame =
      FakeTransport.frames(transport)
      |> Enum.find(fn frame ->
        match?({:ok, {:room_response, ^request_id, _}}, Wire.decode(frame))
      end)

    {:ok, {:room_response, ^request_id, scores}} = Wire.decode(frame)
    scores
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

  test "join_room frame carries reconnection_token", %{room_id: room_id} do
    {_transport, _sid, payload} = join!(room_id)
    assert %{"reconnection_token" => token} = payload
    assert is_binary(token)
    assert byte_size(token) >= 16
  end

  test "unexpected drop keeps the seat and defers leave", %{room_id: room_id} do
    {transport, sid, %{"reconnection_token" => token}} = join!(room_id)
    drop_and_await_slot!(room_id, sid, token, transport)

    # клиент всё ещё "в комнате" (место занято), handle_leave не вызван
    assert {:ok, %{clients: 1}} = Server.listing(room_id)
  end

  test "reconnect/3 validates token and session; while attached the slot is absent",
       %{room_id: room_id} do
    {transport, sid, %{"reconnection_token" => token}} = join!(room_id)

    # слот reconnection появляется только после не-согласованного обрыва
    assert {:error, :invalid_token} = Server.reconnect(room_id, nil, token)

    drop_and_await_slot!(room_id, sid, token, transport)

    assert {:ok, ^sid} = Server.reconnect(room_id, nil, token)
    assert {:ok, ^sid} = Server.reconnect(room_id, sid, token)
    assert {:error, :invalid_token} = Server.reconnect(room_id, sid, "bogus")
    assert {:error, :invalid_token} = Server.reconnect(room_id, "other_session", token)
  end

  test "reattach swaps transport, keeps session_id and logic state", %{room_id: room_id} do
    {transport, sid, %{"reconnection_token" => token}} = join!(room_id)
    bump_score!(room_id, sid, 5)
    assert %{^sid => 5} = request_scores!(transport, room_id, sid, 1)

    drop_and_await_slot!(room_id, sid, token, transport)

    {:ok, new_transport} = FakeTransport.start_link()
    {:ok, join_frame, _state_frame} = Server.reattach(room_id, sid, new_transport, token)

    # повторное рукопожатие: session_id сохранён, токен ротирован
    assert {:ok, {:join_room, payload}} = Wire.decode(join_frame)
    assert %{"session_id" => ^sid, "reconnection_token" => new_token} = payload
    assert new_token != token

    # срез состояния логики сохранён (logic_join не перезапускался)
    assert %{^sid => 5} = request_scores!(new_transport, room_id, sid, 2)
  end

  test "reattach with wrong token or session fails", %{room_id: room_id} do
    {transport, sid, %{"reconnection_token" => token}} = join!(room_id)
    drop_and_await_slot!(room_id, sid, token, transport)

    assert {:error, :invalid_token} = Server.reattach(room_id, sid, self(), "bogus")
    assert {:error, :invalid_token} = Server.reattach(room_id, "other_session", self(), token)

    # валидная пара по-прежнему работает
    assert {:ok, _join, _state} = Server.reattach(room_id, sid, self(), token)
  end

  test "expired reconnect slot removes the client and disposes the room", %{room_id: room_id} do
    {transport, sid, %{"reconnection_token" => token}} = join!(room_id)
    drop_and_await_slot!(room_id, sid, token, transport)

    assert eventually(fn -> not Rooms.alive?(room_id) end, 2000)
  end

  test "consented leave removes the client immediately (no reconnect slot)", %{room_id: room_id} do
    {_transport, sid, %{"reconnection_token" => token}} = join!(room_id)
    FakeTransport.send_frame(room_id, sid, Wire.encode(:leave_room))

    assert eventually(fn -> not Rooms.alive?(room_id) end, 2000)
    assert {:error, _} = Server.reconnect(room_id, sid, token)
  end

  test "reconnect_ttl: false removes the client on drop immediately" do
    {:ok, room_id} = Rooms.start(ExGames.Test.LogicShell, reconnect_ttl: false)
    {transport, _sid, _payload} = join!(room_id)

    Process.unlink(transport)
    Process.exit(transport, :kill)
    assert eventually(fn -> not Rooms.alive?(room_id) end, 2000)
  end

  # -------------------------------------------------------------------------
  # Буфер исходящих кадров окна reconnect (deliver/3): сообщения и дельты,
  # отправленные пока транспорт мёртв, доигрываются при reattach.
  # -------------------------------------------------------------------------

  defmodule OutboxRoom do
    # rate_limit: :infinity — тест буфера шлёт сотни кадров в секунду
    use ExGames.Room,
      max_clients: 4,
      patch_rate: 60_000,
      reconnect_ttl: 60_000,
      rate_limit: :infinity

    @impl true
    def room_init(_options, _room), do: {:ok, nil}

    message "bump", payload, room, _client, state do
      set_state(room, %{"n" => payload["n"]})
      broadcast(room, "bumped", payload)
      {:ok, state}
    end
  end

  test "кадры окна reconnect доигрываются при reattach: join → буфер → снапшот" do
    {:ok, room_id} = Rooms.start(OutboxRoom)
    {transport_a, sid_a, %{"reconnection_token" => token_a}} = join!(room_id)
    {_transport_b, sid_b, _payload_b} = join!(room_id)

    drop_and_await_slot!(room_id, sid_a, token_a, transport_a)

    # сообщение в окне обрыва: B получает сразу, копия A — в буфер
    FakeTransport.send_frame(room_id, sid_b, Wire.encode(:room_data, {"bump", %{"n" => 7}}))

    # комната обработала очередь (bump → буфер A + set_state) до reattach
    sync_room!(room_id)

    {:ok, new_transport} = FakeTransport.start_link()
    {:ok, _join_frame, state_frame} = Server.reattach(room_id, sid_a, new_transport, token_a)

    # комната публиковала set_state — снапшот при reattach есть
    assert {:ok, {:room_state, %{"n" => 7}}} = Wire.decode(state_frame)

    # хронологический порядок: рукопожатие, потерянное сообщение, свежий стейт
    decoded =
      FakeTransport.frames(new_transport)
      |> Enum.map(&elem(Wire.decode(&1), 1))

    assert [
             {:join_room, _},
             {:room_data, "bumped", %{"n" => 7}},
             {:room_state, %{"n" => 7}}
           ] = decoded

    Rooms.stop(room_id)
  end

  test "буфер ограничен: старейшие кадры вытесняются" do
    {:ok, room_id} = Rooms.start(OutboxRoom)
    {transport_a, sid_a, %{"reconnection_token" => token_a}} = join!(room_id)
    {_transport_b, sid_b, _payload_b} = join!(room_id)

    drop_and_await_slot!(room_id, sid_a, token_a, transport_a)

    for n <- 1..300 do
      FakeTransport.send_frame(room_id, sid_b, Wire.encode(:room_data, {"bump", %{"n" => n}}))
    end

    # все 300 broadcast'ов обработаны (буфер уже скаппирован) до reattach
    sync_room!(room_id)

    {:ok, new_transport} = FakeTransport.start_link()
    {:ok, _join_frame, _state_frame} = Server.reattach(room_id, sid_a, new_transport, token_a)

    ns =
      FakeTransport.frames(new_transport)
      |> Enum.flat_map(fn frame ->
        case Wire.decode(frame) do
          {:ok, {:room_data, "bumped", %{"n" => n}}} -> [n]
          _ -> []
        end
      end)

    # последние 256 из 300: старейшие вытеснены
    assert length(ns) == 256
    assert hd(ns) == 45
    assert List.last(ns) == 300

    Rooms.stop(room_id)
  end
end
