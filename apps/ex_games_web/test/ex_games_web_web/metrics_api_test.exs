defmodule ExGamesWebWeb.MetricsAPITest do
  @moduledoc "GET /metrics — доменные метрики в текстовом формате Prometheus (без auth)."

  use ExGamesWebWeb.ConnCase, async: false

  test "GET /metrics отдаёт счётчики, gauge'и ноды и заголовок text/plain", %{conn: conn} do
    :telemetry.execute([:ex_games, :room, :created], %{}, %{room_id: "x", module: __MODULE__})
    ExGames.Telemetry.sample()

    conn = get(conn, "/metrics")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"

    body = response(conn, 200)
    assert body =~ ~r/ex_games_room_created_total \d+/
    assert body =~ ~r/ex_games_node_process_count \d+/
    assert body =~ ~r/ex_games_node_rooms_active \d+/
  end
end
