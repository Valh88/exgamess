defmodule ExGamesWebWeb.AuthAPITest do
  use ExGamesWebWeb.ConnCase, async: false

  test "POST /api/auth/register creates user and returns token", %{conn: conn} do
    conn =
      post(conn, "/api/auth/register", %{"username" => "ann", "password" => "secret123"})

    assert %{"token" => token, "user" => user} = json_response(conn, 201)
    assert is_binary(token)
    assert user["username"] == "ann"
    assert user["roles"] == ["player"]
  end

  test "POST /api/auth/register validates input", %{conn: conn} do
    conn = post(conn, "/api/auth/register", %{"username" => "x", "password" => "1"})
    assert %{"errors" => _} = json_response(conn, 422)
  end

  test "POST /api/auth/login returns token; GET /api/me returns profile", %{conn: conn} do
    post(conn, "/api/auth/register", %{"username" => "bob", "password" => "secret123"})

    conn =
      post(build_conn(), "/api/auth/login", %{"username" => "bob", "password" => "secret123"})

    assert %{"token" => token} = json_response(conn, 200)

    conn = auth_conn(build_conn(), token) |> get("/api/me")
    assert %{"user" => %{"username" => "bob"}} = json_response(conn, 200)
  end

  test "GET /api/me without token → 401", %{conn: conn} do
    conn = get(conn, "/api/me")
    assert json_response(conn, 401)
  end

  test "GET /api/me with invalid token → 401", %{conn: conn} do
    conn = auth_conn(conn, "garbage") |> get("/api/me")
    assert json_response(conn, 401)
  end
end
