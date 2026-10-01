defmodule ExGamesWebWeb.MetricsController do
  @moduledoc """
  `GET /metrics` — доменные метрики ExGames в текстовом формате Prometheus
  (счётчики и gauge'и из `ExGames.Telemetry`). Без auth: значения — агрегаты
  ноды, персональных данных нет; эндпоинт для скрейпера (Prometheus,
  балансировщик, админ-скрипты).
  """

  use ExGamesWebWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(:ok, ExGames.Telemetry.prometheus())
  end
end
