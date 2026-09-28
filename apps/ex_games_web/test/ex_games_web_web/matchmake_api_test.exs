defmodule ExGamesWebWeb.MatchmakeAPITest do
  use ExGamesWebWeb.ConnCase, async: false

  alias ExGames.Room.Server

  setup do
    name = "arena_#{System.unique_integer([:positive])}"
    :ok = ExGames.Matchmaker.define_room(name, ExGamesWeb.Test.Room)
    %{name: name}
  end

  test "matchmake requires auth", %{conn: conn, name: name} do
    conn = post(conn, "/api/matchmake/join_or_create/#{name}", %{})
    assert json_response(conn, 401)
  end

  test "join_or_create returns seat reservation", %{conn: conn, name: name} do
    %{"token" => token} = register_user!(conn)

    conn =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/join_or_create/#{name}", %{})

    assert %{"room_id" => room_id, "session_id" => session_id, "room_name" => ^name} =
             json_response(conn, 200)

    assert {:ok, listing} = Server.listing(room_id)
    assert listing.clients == 1
    assert is_binary(session_id)
  end

  test "options are passed through as filters/metadata", %{conn: conn, name: name} do
    :ok = ExGames.Matchmaker.define_room(name, ExGamesWeb.Test.Room, filter_by: ["mode"])
    %{"token" => token} = register_user!(conn)

    conn =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/join_or_create/#{name}", %{"options" => %{"mode" => "ranked"}})

    assert %{"room_id" => room_id} = json_response(conn, 200)
    assert {:ok, %{metadata: %{"mode" => "ranked"}}} = Server.listing(room_id)
  end

  test "unknown room type → 404 with protocol code", %{conn: conn} do
    %{"token" => token} = register_user!(conn)

    conn =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/join_or_create/never_defined", %{})

    assert %{"error" => %{"code" => 520}} = json_response(conn, 404)
  end

  test "GET /api/rooms lists rooms", %{conn: conn, name: name} do
    %{"token" => token} = register_user!(conn)

    auth_conn(build_conn(), token)
    |> post("/api/matchmake/create/#{name}", %{})

    conn = auth_conn(build_conn(), token) |> get("/api/rooms", %{"room_name" => name})
    assert %{"rooms" => [room]} = json_response(conn, 200)
    assert room["room_name"] == name
  end
end
