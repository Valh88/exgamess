defmodule ExGamesWebWeb.MetricsController do
  @moduledoc """
  `GET /metrics` — визуальная страница метрик ноды: доменные счётчики,
  длительности обработчиков и состояние ноды из `ExGames.Telemetry`.
  Страница сама себе layout (эндпоинт вне `:browser`-пайплайна — сессия
  и flash не нужны), автообновление — meta refresh 5 секунд. Без auth:
  значения — агрегаты ноды, персональных данных нет. Машиночитаемый
  формат Prometheus при необходимости даёт `ExGames.Telemetry.prometheus/0`.
  """

  use ExGamesWebWeb, :controller

  def show(conn, _params) do
    %{counters: counters, gauges: gauges} = ExGames.Telemetry.snapshot()

    {node_gauges, durations} =
      Enum.split_with(gauges, fn {name, _} -> String.starts_with?(name, "node.") end)

    conn
    |> put_format("html")
    |> put_layout(false)
    |> render(:index,
      counters: sort_rows(counters),
      durations: sort_rows(durations),
      node_gauges: sort_rows(node_gauges),
      node: Atom.to_string(node()),
      taken_at: Calendar.strftime(DateTime.utc_now(), "%d.%m.%Y %H:%M:%S UTC")
    )
  end

  defp sort_rows(rows), do: Enum.sort_by(rows, fn {name, _} -> name end)
end
