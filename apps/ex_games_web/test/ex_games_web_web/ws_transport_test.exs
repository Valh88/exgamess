defmodule ExGamesWebWeb.WsTransportTest do
  @moduledoc """
  Интеграционный тест WS-транспорта через настоящий HTTP-сервер:
  регистрация → matchmake → WebSocket-подключение → кадры.
  """

  use ExGamesWebWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias ExGames.Wire

  @port 4045
  @base "ws://127.0.0.1:#{@port}"

  setup do
    name = "arena_#{System.unique_integer([:positive])}"
    :ok = ExGames.Matchmaker.define_room(name, ExGamesWeb.Test.Room)
    %{name: name}
  end

  test "full two-phase join over real WebSocket", %{conn: conn, name: name} do
    %{"token" => token} = register_user!(conn)

    reservation =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/join_or_create/#{name}", %{})
      |> json_response(200)

    client = start_client!(@base, reservation)

    # join_room рукопожатие и broadcast "join" (клиент возвращает уже декодированные кортежи)
    assert {:join_room, %{"session_id" => sid, "room_id" => rid}} =
             wait_frame!(client, :join_room)

    assert sid == reservation["session_id"]
    assert rid == reservation["room_id"]

    assert {:room_data, "join", %{"session_id" => ^sid}} =
             wait_frame!(client, {:room_data, "join"})

    # клиент шлёт сообщение — получает broadcast
    send_data(client, Wire.encode(:room_data, {"echo", %{"x" => 42}}))
    assert {:room_data, "echo", %{"x" => 42}} = wait_frame!(client, {:room_data, "echo"})

    ok(client)
  end

  test "ws without reservation is closed with protocol error", %{conn: _conn, name: _name} do
    # подключение с левым session_id: attach fails → error frame → закрытие
    client = start_client!(@base, %{"room_id" => "nonexistent", "session_id" => "bogus"})

    assert {:error, %{"code" => 522}} = wait_frame!(client, :error)
    ok(client)
  end

  test "kick on invalid frame closes cleanly and ignores trailing frames", %{
    conn: conn,
    name: name
  } do
    %{"token" => token} = register_user!(conn)

    reservation =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/join_or_create/#{name}", %{})
      |> json_response(200)

    client = start_client!(@base, reservation)
    assert {:join_room, _} = wait_frame!(client, :join_room)

    logs =
      capture_log(fn ->
        # неизвестный опкод → кик 4002; следом уже в закрывающемся сокете
        # прилетает ещё кадр — он не должен ронять процесс соединения
        # (раньше: FunctionClauseError в handle_in для состояния close)
        send_data(client, <<99>>)
        send_data(client, Wire.encode(:ping))

        assert {:error, %{"code" => 4002, "message" => "invalid frame"}} =
                 wait_frame!(client, :error)

        # сервер закрывает соединение согласованным close-кадром с тем же
        # кодом (Bandit передаёт только код, без reason)
        assert {4002, ""} = ExGamesWeb.Test.WsClient.wait_close(client)
      end)

    refute logs =~ "FunctionClauseError"
    refute logs =~ "terminating"

    ok(client)
  end

  test "reconnect over real WebSocket keeps session and replays snapshot", %{
    conn: conn,
    name: name
  } do
    %{"token" => token} = register_user!(conn)

    reservation =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/join_or_create/#{name}", %{})
      |> json_response(200)

    room_id = reservation["room_id"]
    session_id = reservation["session_id"]
    client = start_client!(@base, reservation)

    assert {:join_room, %{"session_id" => ^session_id, "reconnection_token" => rec_token}} =
             wait_frame!(client, :join_room)

    # согласованное закрытие сокета (без leave_room) — комната держит слот
    ok(client)

    # ждём, пока комната обработает обрыв и появится слот reconnection
    assert eventually(fn ->
             match?(
               {:ok, ^session_id},
               ExGames.Room.Server.reconnect(room_id, session_id, rec_token)
             )
           end)

    # повторное подключение по токену
    {:ok, client2} =
      ExGamesWeb.Test.WsClient.start_link(@base, room_id, session_id, rec_token)

    assert {:join_room, %{"session_id" => ^session_id}} = wait_frame!(client2, :join_room)

    # сессия жива: запрос обрабатывается после reconnect
    send_data(client2, Wire.encode(:room_request, {7, "whoami", %{}}))

    assert {:room_response, 7, %{"session_id" => ^session_id}} =
             wait_frame!(client2, {:room_response, 7})

    ok(client2)
  end

  defp eventually(fun, timeout \\ 2000) do
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

  # -------------------------------------------------------------------------
  # Минимальный WS-клиент поверх :gun-подобного API без зависимости:
  # используем :websocket_client? Нет — Erlang/OTP не имеет встроенного
  # WS-клиента, поэтому тестируем через websock_adapter's test client
  # (websock_client отсутствует) — поднимаем raw TCP HTTP upgrade вручную.
  # Для простоты используем :hackney? Вместо зависимостей — минимальный
  # реализованный клиент на gen_tcp (см. ExGamesWeb.Test.WsClient).
  # -------------------------------------------------------------------------

  defp start_client!(base, reservation) do
    {:ok, client} =
      ExGamesWeb.Test.WsClient.start_link(
        base,
        reservation["room_id"],
        reservation["session_id"]
      )

    client
  end

  defp send_data(client, frame), do: ExGamesWeb.Test.WsClient.send_binary(client, frame)

  defp wait_frame!(client, kind), do: ExGamesWeb.Test.WsClient.wait_frame(client, kind)

  defp ok(client), do: ExGamesWeb.Test.WsClient.stop(client)
end
