defmodule ExGamesWebWeb.ReconnectAPITest do
  @moduledoc """
  REST-часть reconnect-флоу: `POST /matchmake/join_by_id/:room_id` и
  `POST /matchmake/reconnect/:room_id`.
  """

  use ExGamesWebWeb.ConnCase, async: false

  alias ExGames.Wire

  setup do
    name = "arena_#{System.unique_integer([:positive])}"
    :ok = ExGames.Matchmaker.define_room(name, ExGamesWeb.Test.Room)
    %{name: name}
  end

  defp create_reservation(conn, name) do
    %{"token" => token} = register_user!(conn)

    reservation =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/join_or_create/#{name}", %{})
      |> json_response(200)

    {token, reservation}
  end

  test "join_by_id reserves a seat in the existing room", %{conn: conn, name: name} do
    {token, %{"room_id" => room_id}} = create_reservation(conn, name)

    conn =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/join_by_id/#{room_id}", %{})

    assert %{"room_id" => ^room_id, "session_id" => session_id, "room_name" => ^name} =
             json_response(conn, 200)

    assert {:ok, listing} = ExGames.Room.Server.listing(room_id)
    assert listing.clients == 2
    assert is_binary(session_id)
  end

  test "join_by_id on unknown room → 404/522", %{conn: conn} do
    %{"token" => token} = register_user!(conn)

    conn =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/join_by_id/nonexistent", %{})

    assert %{"error" => %{"code" => 522}} = json_response(conn, 404)
  end

  test "reconnect endpoint resolves session by token after drop", %{conn: conn, name: name} do
    {token, %{"room_id" => room_id, "session_id" => session_id}} = create_reservation(conn, name)

    {transport, join_frame, _state_frame} =
      ExGamesWeb.Test.FakeTransport.attach!(room_id, session_id)

    assert {:ok, {:join_room, %{"reconnection_token" => rec_token}}} = Wire.decode(join_frame)

    # имитируем не-согласованный обрыв: транспорт умирает
    # (транспорт слинкован с тестом — отвязываемся, чтобы :kill не убил тест)
    Process.unlink(transport)
    Process.exit(transport, :kill)

    assert eventually(fn ->
             match?(
               {:ok, ^session_id},
               ExGames.Room.Server.reconnect(room_id, session_id, rec_token)
             )
           end)

    conn =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/reconnect/#{room_id}", %{
        "session_id" => session_id,
        "reconnection_token" => rec_token
      })

    assert %{
             "room_id" => ^room_id,
             "session_id" => ^session_id,
             "reconnection_token" => ^rec_token
           } = json_response(conn, 200)
  end

  test "reconnect with invalid token → 404/522", %{conn: conn, name: name} do
    {token, %{"room_id" => room_id, "session_id" => session_id}} = create_reservation(conn, name)

    conn =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/reconnect/#{room_id}", %{
        "session_id" => session_id,
        "reconnection_token" => "bogus"
      })

    assert %{"error" => %{"code" => 522}} = json_response(conn, 404)
  end

  test "reconnect requires auth", %{conn: conn, name: name} do
    {_, %{"room_id" => room_id}} = create_reservation(conn, name)

    conn = post(conn, "/api/matchmake/reconnect/#{room_id}", %{"reconnection_token" => "x"})
    assert json_response(conn, 401)
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
end
