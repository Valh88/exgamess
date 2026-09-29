defmodule ExGamesWebWeb.SavesAPITest do
  # async: false — SQLite не держит параллельные записи нескольких модулей.
  use ExGamesWebWeb.ConnCase, async: false

  # PUT/GET/DELETE /api/saves — payload непрозрачен, изолирован по токену.

  test "PUT сохраняет, GET возвращает payload байт-в-байт (кириллица, вложенность)", %{conn: conn} do
    %{"token" => token} = register_user!(conn)
    payload = %{"level" => 3, "note" => "привет мир", "pos" => %{"x" => 1, "y" => 2}}

    conn =
      auth_conn(build_conn(), token)
      |> put("/api/saves/world1", %{"payload" => payload})

    assert %{"key" => "world1", "payload" => ^payload, "updated_at" => at} =
             json_response(conn, 200)

    assert is_binary(at)

    conn = auth_conn(build_conn(), token) |> get("/api/saves/world1")
    assert %{"key" => "world1", "payload" => ^payload} = json_response(conn, 200)
  end

  test "повторный PUT в тот же слот перезаписывает payload", %{conn: conn} do
    %{"token" => token} = register_user!(conn)
    headers = auth_conn(build_conn(), token)

    headers |> put("/api/saves/slot", %{"payload" => %{"v" => 1}})
    headers |> put("/api/saves/slot", %{"payload" => %{"v" => 2}})

    conn = headers |> get("/api/saves/slot")
    assert %{"payload" => %{"v" => 2}} = json_response(conn, 200)

    conn = headers |> get("/api/saves")
    assert %{"saves" => [%{"key" => "slot"}]} = json_response(conn, 200)
  end

  test "список слотов не содержит payload", %{conn: conn} do
    %{"token" => token} = register_user!(conn)
    headers = auth_conn(build_conn(), token)

    headers |> put("/api/saves/alpha", %{"payload" => %{"v" => 1}})
    headers |> put("/api/saves/beta", %{"payload" => %{"v" => 2}})

    conn = headers |> get("/api/saves")
    %{"saves" => saves} = json_response(conn, 200)

    assert Enum.map(saves, & &1["key"]) |> Enum.sort() == ["alpha", "beta"]
    refute Map.has_key?(hd(saves), "payload")
  end

  test "DELETE удаляет слот; после — 404, повторный DELETE — 404", %{conn: conn} do
    %{"token" => token} = register_user!(conn)
    headers = auth_conn(build_conn(), token)

    headers |> put("/api/saves/slot", %{"payload" => %{"v" => 1}})

    conn = headers |> delete("/api/saves/slot")
    assert conn.status == 204

    conn = headers |> get("/api/saves/slot")
    assert json_response(conn, 404)

    conn = headers |> delete("/api/saves/slot")
    assert json_response(conn, 404)
  end

  test "слоты другого пользователя не видны", %{conn: conn} do
    %{"token" => token_a} = register_user!(conn)
    %{"token" => token_b} = register_user!(conn)

    auth_conn(build_conn(), token_a) |> put("/api/saves/secret", %{"payload" => %{"v" => 1}})

    conn = auth_conn(build_conn(), token_b) |> get("/api/saves/secret")
    assert json_response(conn, 404)
  end

  test "payload не-объект отклоняется (400), отсутствие payload — тоже", %{conn: conn} do
    %{"token" => token} = register_user!(conn)
    headers = auth_conn(build_conn(), token)

    conn = headers |> put("/api/saves/bad", %{"payload" => "not-a-map"})
    assert json_response(conn, 400)

    conn = headers |> put("/api/saves/bad", %{"other" => 1})
    assert json_response(conn, 400)
  end

  test "payload больше лимита — 413", %{conn: conn} do
    %{"token" => token} = register_user!(conn)
    big = String.duplicate("х", 300_000)

    conn =
      auth_conn(build_conn(), token)
      |> put("/api/saves/big", %{"payload" => %{"blob" => big}})

    assert json_response(conn, 413)
  end

  test "без токена — 401", %{conn: conn} do
    conn = put(conn, "/api/saves/slot", %{"payload" => %{"v" => 1}})
    assert json_response(conn, 401)

    conn = get(build_conn(), "/api/saves/slot")
    assert json_response(conn, 401)
  end
end
