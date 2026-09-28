defmodule ExGamesWebWeb.HealthAPITest do
  @moduledoc """
  Фаза 3 плана прод-минимума: пробы liveness (`/healthz`) и readiness
  (`/readyz`), маппинг `{:error, :draining}` матчмейкера в HTTP 503.
  """

  use ExGamesWebWeb.ConnCase, async: false

  setup do
    on_exit(fn -> ExGames.Runtime.Drain.reset() end)
    :ok
  end

  test "GET /healthz always responds ok", %{conn: conn} do
    assert %{"status" => "ok"} = json_response(get(conn, "/healthz"), 200)
  end

  test "GET /readyz reflects drain state", %{conn: conn} do
    assert %{"status" => "ok"} = json_response(get(conn, "/readyz"), 200)

    assert :ok = ExGames.Runtime.Drain.drain(2000)

    assert %{"status" => "draining"} = json_response(get(build_conn(), "/readyz"), 503)
  end

  test "matchmake returns 503 while draining", %{conn: conn} do
    name = "drain_web_#{System.unique_integer([:positive])}"
    :ok = ExGames.Matchmaker.define_room(name, ExGamesWeb.Test.Room)
    %{"token" => token} = register_user!(conn)

    assert :ok = ExGames.Runtime.Drain.drain(2000)

    conn =
      auth_conn(build_conn(), token)
      |> post("/api/matchmake/join_or_create/#{name}", %{})

    assert %{"error" => %{"code" => 503, "message" => "draining"}} = json_response(conn, 503)
  end
end
