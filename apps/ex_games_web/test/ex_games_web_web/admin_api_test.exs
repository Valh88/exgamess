defmodule ExGamesWebWeb.AdminAPITest do
  use ExGamesWebWeb.ConnCase, async: true

  test "admin endpoints require admin role", %{conn: conn} do
    %{"token" => token} = register_user!(conn)

    conn = auth_conn(build_conn(), token) |> get("/api/admin/users")
    assert json_response(conn, 403)
  end

  test "admin can list users, grant roles, ban", %{conn: conn} do
    # создаем админа напрямую через контекст
    {:ok, admin} =
      ExGames.Account.register(%{"username" => "root", "password" => "secret123"})

    {:ok, _role, _} = ExGames.Account.grant_role(admin, :admin)
    {:ok, {:token, admin_token, _}} = ExGames.Account.login("root", "secret123")

    %{"user" => %{"id" => user_id}} = register_user!(conn, "victim")

    conn = auth_conn(build_conn(), admin_token) |> get("/api/admin/users")
    assert %{"users" => users} = json_response(conn, 200)
    assert length(users) >= 2

    conn = auth_conn(build_conn(), admin_token) |> get("/api/admin/users/#{user_id}")
    assert %{"user" => %{"id" => ^user_id}} = json_response(conn, 200)

    conn =
      auth_conn(build_conn(), admin_token)
      |> post("/api/admin/users/#{user_id}/roles", %{"role" => "moderator"})

    assert %{"user" => %{"roles" => roles}} = json_response(conn, 200)
    assert "moderator" in roles

    conn =
      auth_conn(build_conn(), admin_token)
      |> post("/api/admin/users/#{user_id}/ban", %{"reason" => "cheat"})

    assert %{"user" => %{"banned_at" => banned_at}} = json_response(conn, 200)
    assert banned_at

    conn =
      auth_conn(build_conn(), admin_token)
      |> post("/api/admin/users/#{user_id}/unban", %{})

    assert %{"user" => %{"banned_at" => nil}} = json_response(conn, 200)
  end
end
