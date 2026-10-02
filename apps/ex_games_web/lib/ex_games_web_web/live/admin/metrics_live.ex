defmodule ExGamesWebWeb.Admin.MetricsLive do
  @moduledoc """
  Метрики ноды: доменные счётчики, длительности обработчиков и состояние
  ноды из `ExGames.Telemetry`, опрос каждые 2 секунды. Полный снимок без
  фильтров и лимитов (в отличие от панели Обзора).
  """

  use ExGamesWebWeb, :live_view

  alias ExGamesWebWeb.MetricsHTML

  @poll_ms 2000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(current_path: "/admin/metrics", page_title: "Метрики — ExGames Admin")
      |> refresh()

    if connected?(socket), do: schedule_poll()

    {:ok, socket}
  end

  @impl true
  def handle_info(:poll, socket) do
    schedule_poll()
    {:noreply, refresh(socket)}
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_ms)

  defp refresh(socket) do
    %{counters: counters, gauges: gauges} = ExGames.Telemetry.snapshot()

    {node_gauges, durations} =
      Enum.split_with(gauges, fn {name, _} -> String.starts_with?(name, "node.") end)

    assign(socket,
      counters: sort_rows(counters),
      durations: sort_rows(durations),
      node_gauges: sort_rows(node_gauges)
    )
  end

  defp sort_rows(rows), do: Enum.sort_by(rows, fn {name, _} -> name end)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} admin_user={@admin_user} current_path={@current_path}>
      <div class="space-y-6">
        <div>
          <h1 class="text-xl font-semibold text-slate-100">Метрики</h1>

          <p class="text-sm text-slate-500">
            Доменные события, длительности обработчиков и состояние ноды — обновление каждые 2 с
          </p>
        </div>

        <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <.panel
            title="Счётчики"
            subtitle="События :telemetry с последнего старта ноды"
            class="lg:col-span-2"
          >
            <.admin_table
              id="metrics-counters"
              rows={rows(@counters)}
              row_id={fn m -> "metric-counter-#{String.replace(m.name, ".", "-")}" end}
              empty="Событий пока не было"
            >
              <:col :let={m} label="Метрика">
                <span class="font-mono text-xs text-indigo-300">{m.name}</span>
              </:col>

              <:col :let={m} label="Значение">
                <span class="tabular-nums">{MetricsHTML.format_value(m.name, m.value)}</span>
              </:col>
            </.admin_table>
          </.panel>

          <.panel
            title="Длительности обработчиков"
            subtitle="мс, последнее значение"
          >
            <.admin_table
              id="metrics-durations"
              rows={rows(@durations)}
              row_id={fn m -> "metric-duration-#{String.replace(m.name, ".", "-")}" end}
              empty="Обработчиков ещё не вызывали"
            >
              <:col :let={m} label="Метрика">
                <span class="font-mono text-xs text-indigo-300">{m.name}</span>
              </:col>

              <:col :let={m} label="Значение">
                <span class="tabular-nums">{MetricsHTML.format_value(m.name, m.value)}</span>
              </:col>
            </.admin_table>
          </.panel>

          <.panel title="Состояние ноды" subtitle="Сэмпл каждые 10 с">
            <.admin_table
              id="metrics-node"
              rows={rows(@node_gauges)}
              row_id={fn m -> "metric-node-#{String.replace(m.name, ".", "-")}" end}
              empty="Нет данных"
            >
              <:col :let={m} label="Метрика">
                <span class="font-mono text-xs text-indigo-300">{m.name}</span>
              </:col>

              <:col :let={m} label="Значение">
                <span class="tabular-nums">{MetricsHTML.format_value(m.name, m.value)}</span>
              </:col>
            </.admin_table>
          </.panel>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  defp rows(list), do: Enum.map(list, fn {name, value} -> %{name: name, value: value} end)
end
