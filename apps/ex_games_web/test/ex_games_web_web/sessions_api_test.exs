defmodule ExGamesWebWeb.SessionsApiTest do
  @moduledoc """
  Живые сессии и восстановление: `GET /api/me/sessions` (presence по user_id)
  и `POST /api/matchmake/resume/:room_id` (reclaim слота по identity юзера).

  Сравнения — только по комнате своего теста: presence живёт в процессе
  трекера вне SQL Sandbox, а откат транзакций переиспользует user_id —
  записи упавших соседних тестов могут совпадать по id.
  """
  use ExGamesWebWeb.ConnCase, async: false

  alias ExGamesWeb.Test.WsClient

  @port 4045
  @base "ws://127.0.0.1:#{@port}"

  setup do
    name = "arena_#{System.unique_integer([:positive])}"
    :ok = ExGames.Matchmaker.define_room(name, ExGamesWeb.Test.Room)
    %{name: name}
  end

  test "me/sessions lists rooms where the user is online", %{conn: conn, name: name} do
    %{"token" => token} = register_user!(conn)

    reservation =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/join_or_create/#{name}", %{})
      |> json_response(200)

    # до подключения комнаты этого типа в сессиях нет
    sessions = fetch_sessions!(token)
    assert Enum.reject(sessions, &(&1["room_name"] != name)) == []

    {:ok, client} = WsClient.start_link(@base, reservation["room_id"], reservation["session_id"])
    assert {:join_room, _} = WsClient.wait_frame(client, :join_room)

    assert [session] = fetch_sessions!(token) |> Enum.filter(&(&1["room_name"] == name))
    assert session["room_id"] == reservation["room_id"]

    # другой пользователь эту сессию не видит
    %{"token" => other} = register_user!(conn, "other_#{System.unique_integer([:positive])}")

    assert fetch_sessions!(other) |> Enum.filter(&(&1["room_name"] == name)) == []

    WsClient.stop(client)
  end

  test "resume returns a fresh token for the reconnect slot; session survives", %{
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

    {:ok, client} = WsClient.start_link(@base, room_id, session_id)
    assert {:join_room, _} = WsClient.wait_frame(client, :join_room)

    # не-согласованный обрыв: комната держит reconnect-слот (до 30с)
    WsClient.stop(client)

    # пока транспорта нет — resume отклоняется; слот появился — отдаёт токен
    resumed =
      eventually(fn ->
        case resume(room_id, token) do
          {:ok, body} -> body
          :error -> nil
        end
      end)

    assert resumed["session_id"] == session_id
    assert is_binary(resumed["reconnection_token"])

    # токен работает: обычный reconnect-флоу восстанавливает сессию
    {:ok, client2} =
      WsClient.start_link(@base, room_id, session_id, resumed["reconnection_token"])

    assert {:join_room, %{"session_id" => ^session_id}} = WsClient.wait_frame(client2, :join_room)
    WsClient.stop(client2)
  end

  test "resume rejects live sessions", %{conn: conn, name: name} do
    %{"token" => token} = register_user!(conn)

    reservation =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/join_or_create/#{name}", %{})
      |> json_response(200)

    room_id = reservation["room_id"]

    {:ok, client} = WsClient.start_link(@base, room_id, reservation["session_id"])
    assert {:join_room, _} = WsClient.wait_frame(client, :join_room)

    # транспорт жив — слота нет, восстанавливать нечего
    assert {:resp, %{status: 404}} = resume_raw(room_id, token)

    WsClient.stop(client)
  end

  test "sessions require auth", %{conn: conn} do
    conn |> get("/api/me/sessions") |> json_response(401)
  end

  defp fetch_sessions!(token) do
    auth_conn(build_conn(), token)
    |> get("/api/me/sessions")
    |> json_response(200)
    |> Map.fetch!("sessions")
  end

  defp resume_raw(room_id, token) do
    resp = auth_conn(build_conn(), token) |> post("/api/matchmake/resume/#{room_id}", %{})
    {:resp, resp}
  end

  defp resume(room_id, token) do
    case resume_raw(room_id, token) do
      {:resp, %{status: 200} = resp} ->
        {:ok, json_response(resp, 200)}

      _ ->
        :error
    end
  end

  defp eventually(fun, timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("eventually condition not met")

        Process.sleep(20)
        do_eventually(fun, deadline)

      value ->
        value
    end
  end
end
