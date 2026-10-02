defmodule ExGamesWebWeb.MetricsAPITest do
  @moduledoc "GET /metrics — визуальная страница метрик ноды (без auth)."

  use ExGamesWebWeb.ConnCase, async: false

  test "GET /metrics отдаёт HTML со счётчиками и gauge'ами ноды", %{conn: conn} do
    :telemetry.execute([:ex_games, :room, :created], %{}, %{room_id: "x", module: __MODULE__})
    ExGames.Telemetry.sample()

    conn = get(conn, "/metrics")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"

    body = response(conn, 200)
    assert body =~ "Метрики ноды"
    assert body =~ "room.created"
    assert body =~ "node.process_count"
    assert body =~ "node.rooms_active"
  end
end
