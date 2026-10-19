defmodule ExGamesWebWeb.WsGatewayTest do
  @moduledoc """
  Интеграционный тест мультиплексированного сокета `GET /ws` через настоящий
  HTTP-сервер: одна WS-сессия, несколько комнат, mux-конверты, реконнект.
  """

  use ExGamesWebWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias ExGames.Room.Server
  alias ExGames.Wire
  alias ExGamesWeb.Test.WsClient

  @port 4045
  @base "ws://127.0.0.1:#{@port}"

  setup do
    name = "arena_#{System.unique_integer([:positive])}"
    other = "other_#{System.unique_integer([:positive])}"
    :ok = ExGames.Matchmaker.define_room(name, ExGamesWeb.Test.Room)
    :ok = ExGames.Matchmaker.define_room(other, ExGamesWeb.Test.Room)
    %{name: name, other: other}
  end

  test "two rooms over one gateway socket: mux frames tagged per room", %{
    conn: conn,
    name: name,
    other: other
  } do
    %{"token" => token} = register_user!(conn)

    reservation1 = reserve!(token, name)
    reservation2 = reserve!(token, other)
    {:ok, client} = WsClient.start_gateway_link(@base)

    # вход в обе комнаты одним сокетом
    send_data(client, enter_frame(reservation1))
    send_data(client, enter_frame(reservation2))

    assert {room_id1, {:join_room, %{"session_id" => sid1}}} =
             wait_join(client, reservation1["room_id"])

    assert {room_id2, {:join_room, %{"session_id" => sid2}}} =
             wait_join(client, reservation2["room_id"])

    # каждая комната помечена своим room_id в конверте
    assert room_id1 == reservation1["room_id"]
    assert room_id2 == reservation2["room_id"]
    assert sid1 == reservation1["session_id"]
    assert sid2 == reservation2["session_id"]

    # кадры в комнату идут wrapнутыми, ответы возвращаются с тегом комнаты
    send_data(
      client,
      Wire.encode(:mux, {reservation1["room_id"], Wire.encode(:room_data, {"echo", %{"x" => 7}})})
    )

    assert {^room_id1, {:room_data, "echo", %{"x" => 7}}} =
             wait_inner(client, room_id1, fn d -> match?({:room_data, "echo", _}, d) end)

    ok(client)
  end

  test "kick from one room closes only its channel, socket and neighbour alive", %{
    conn: conn,
    name: name,
    other: other
  } do
    %{"token" => token} = register_user!(conn)

    reservation1 = reserve!(token, name)
    reservation2 = reserve!(token, other)
    {:ok, client} = WsClient.start_gateway_link(@base)

    room1 = reservation1["room_id"]
    room2 = reservation2["room_id"]

    send_data(client, enter_frame(reservation1))
    send_data(client, enter_frame(reservation2))
    {^room1, {:join_room, _}} = wait_join(client, room1)
    {^room2, {:join_room, _}} = wait_join(client, room2)

    # невалидный внутренний кадр → комната кикает сессию: mux_closed для
    # одного room_id, соседний канал и сам сокет продолжают работать
    send_data(client, Wire.encode(:mux, {room1, <<99>>}))

    assert {:mux_closed, ^room1, 4002, "invalid frame"} =
             WsClient.wait_frame(client, {:mux_closed, room1})

    # сосед жив: запрос-ответ через вторую комнату
    send_data(client, Wire.encode(:mux, {room2, Wire.encode(:room_request, {11, "whoami", %{}})}))

    assert {^room2, {:room_response, 11, %{"session_id" => _}}} =
             wait_inner(client, room2, fn d -> match?({:room_response, 11, _}, d) end)

    ok(client)
  end

  test "gateway socket drop holds reconnect slots; re-enter by token reattaches", %{
    conn: conn,
    name: name,
    other: other
  } do
    %{"token" => token} = register_user!(conn)

    reservation1 = reserve!(token, name)
    reservation2 = reserve!(token, other)
    {:ok, client} = WsClient.start_gateway_link(@base)

    send_data(client, enter_frame(reservation1))
    send_data(client, enter_frame(reservation2))

    assert {_, {:join_room, %{"reconnection_token" => rec_token1}}} =
             wait_join(client, reservation1["room_id"])

    assert {_, {:join_room, %{"reconnection_token" => rec_token2}}} =
             wait_join(client, reservation2["room_id"])

    # не-согласованный обрыв сокета: обе комнаты держат reconnect-слоты
    logs =
      capture_log(fn ->
        WsClient.stop(client)

        room_id1 = reservation1["room_id"]
        room_id2 = reservation2["room_id"]
        sid1 = reservation1["session_id"]
        sid2 = reservation2["session_id"]

        assert eventually(fn ->
                 match?({:ok, ^sid1}, Server.reconnect(room_id1, sid1, rec_token1)) and
                   match?({:ok, ^sid2}, Server.reconnect(room_id2, sid2, rec_token2))
               end)
      end)

    refute logs =~ "FunctionClauseError"

    # новый сокет: повторный вход по токенам (reattach, ротация токенов)
    {:ok, client2} = WsClient.start_gateway_link(@base)

    send_data(
      client2,
      Wire.encode(:room_enter, %{
        room_id: reservation1["room_id"],
        session_id: reservation1["session_id"],
        reconnection_token: rec_token1
      })
    )

    assert {_, {:join_room, %{"reconnection_token" => new_token}}} =
             wait_join(client2, reservation1["room_id"])

    assert new_token != rec_token1
    ok(client2)
  end

  test "duplicate room_enter is rejected, first channel keeps working", %{
    conn: conn,
    name: name
  } do
    %{"token" => token} = register_user!(conn)
    reservation = reserve!(token, name)

    {:ok, client} = WsClient.start_gateway_link(@base)
    send_data(client, enter_frame(reservation))
    {room_id, {:join_room, _}} = wait_join(client, reservation["room_id"])

    # повторный вход в ту же комнату тем же сокетом — отказ
    send_data(client, enter_frame(reservation))

    assert {:mux_closed, ^room_id, 522, "already entered"} =
             WsClient.wait_frame(client, {:mux_closed, room_id})

    # первый канал жив
    send_data(
      client,
      Wire.encode(:mux, {room_id, Wire.encode(:room_request, {3, "whoami", %{}})})
    )

    assert {^room_id, {:room_response, 3, _}} =
             wait_inner(client, room_id, fn d -> match?({:room_response, 3, _}, d) end)

    ok(client)
  end

  test "keepalive: bare ping on gateway socket is echoed", %{conn: _conn} do
    {:ok, client} = WsClient.start_gateway_link(@base)
    send_data(client, Wire.encode(:ping))
    assert {:ping} = WsClient.wait_frame(client, :ping)
    ok(client)
  end

  test "invalid outer frame kicks the whole gateway socket", %{conn: _conn} do
    {:ok, client} = WsClient.start_gateway_link(@base)

    send_data(client, <<99>>)

    assert {:error, %{"code" => 522, "message" => "invalid frame"}} =
             WsClient.wait_frame(client, :error)

    assert {4002, ""} = WsClient.wait_close(client)

    ok(client)
  end

  # -------------------------------------------------------------------------
  # helpers
  # -------------------------------------------------------------------------

  defp reserve!(token, name) do
    auth_conn(build_conn(), token)
    |> post("/api/matchmake/join_or_create/#{name}", %{})
    |> json_response(200)
  end

  defp enter_frame(reservation) do
    Wire.encode(:room_enter, %{
      room_id: reservation["room_id"],
      session_id: reservation["session_id"]
    })
  end

  # ждёт mux{room_id, join_room} и возвращает {room_id, decoded_inner}
  defp wait_join(client, room_id) do
    frame =
      WsClient.wait_where(client, fn
        {:mux, ^room_id, inner} -> match?({:join_room, _}, safe_decode(inner))
        _ -> false
      end)

    case frame do
      {:mux, ^room_id, inner} -> {room_id, safe_decode(inner)}
    end
  end

  # ждёт mux{room_id, inner}, где внутренний кадр удовлетворяет предикату
  defp wait_inner(client, room_id, inner_pred) do
    frame =
      WsClient.wait_where(client, fn
        {:mux, ^room_id, inner} ->
          match?({:ok, _}, Wire.decode(inner)) and inner_pred.(safe_decode(inner))

        _ ->
          false
      end)

    case frame do
      {:mux, ^room_id, inner} -> {room_id, safe_decode(inner)}
    end
  end

  defp safe_decode(frame) do
    {:ok, decoded} = Wire.decode(frame)
    decoded
  end

  defp send_data(client, frame), do: WsClient.send_binary(client, frame)

  defp ok(client), do: WsClient.stop(client)

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
end
