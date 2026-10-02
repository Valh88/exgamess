defmodule ExGamesWebWeb.Admin.DashboardLive do
  @moduledoc """
  Обзор: живые счётчики (юзеры, онлайн, комнаты, клиенты), дренаж и типы
  комнат. Все чтения дешёвые (ETS/Registry/Tracker + один агрегат БД),
  опрос каждые 2 секунды.

  Drain — блокирующий вызов (до `:drain_timeout_ms`), поэтому выполняется
  в отдельной задаче; статус панели обновляется следующим опросом.
  """

  use ExGamesWebWeb, :live_view

  @poll_ms 2000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(current_path: "/admin", page_title: "Обзор — ExGames Admin")
      |> refresh()

    if connected?(socket), do: schedule_poll()

    {:ok, socket}
  end

  @impl true
  def handle_info(:poll, socket) do
    schedule_poll()
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("drain", _params, socket) do
    Task.start(&ExGames.Runtime.Drain.drain/0)
    {:noreply, put_flash(socket, :info, "Дренаж запущен: комнаты закрываются с кодом 4001")}
  end

  def handle_event("reset_drain", _params, socket) do
    ExGames.Runtime.Drain.reset()

    {:noreply,
     socket |> refresh() |> put_flash(:info, "Дренаж сброшен — приём трафика восстановлен")}
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_ms)

  defp refresh(socket) do
    listings = ExGames.Matchmaker.all_listings()
    definitions = ExGames.Matchmaker.definitions()

    counts_by_type =
      Enum.map(definitions, fn {name, _module} ->
        live = Enum.count(listings, &(&1.room_name == name))
        %{id: name, name: name, live: live}
      end)
      |> Enum.sort_by(& &1.name)

    %{counters: counters, gauges: gauges} = ExGames.Telemetry.snapshot()

    assign(socket,
      users_total: users_total(),
      online: map_size(ExGames.Presence.list_online()),
      rooms: ExGames.Rooms.count(),
      clients: Enum.sum(Enum.map(listings, & &1.clients)),
      draining: ExGames.Runtime.Drain.draining?(),
      types: counts_by_type,
      unlisted: Enum.count(listings, &is_nil(&1.room_name)),
      metrics: metrics_rows(counters, gauges)
    )
  end

  # метрики панели: доменные счётчики + gauge'и ноды (все — с последнего
  # старта ноды; полный снимок — GET /metrics)
  defp metrics_rows(counters, gauges) do
    counters =
      counters
      |> Enum.reject(fn {name, _} -> String.starts_with?(name, "room.message") end)
      |> Enum.map(fn {name, value} -> %{name: name, value: value} end)

    gauges =
      gauges
      |> Enum.take(12)
      |> Enum.map(fn {name, value} -> %{name: name, value: value} end)

    (counters ++ gauges)
    |> Enum.sort_by(& &1.name)
  end

  defp users_total, do: ExGames.Account.list_users(page_size: 1).total

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} admin_user={@admin_user} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-xl font-semibold text-slate-100">Обзор</h1>

            <p class="text-sm text-slate-500">Живое состояние сервера</p>
          </div>

          <div class="flex items-center gap-3">
            <span
              id="drain-status"
              class={[
                "inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-xs font-medium",
                @draining && "bg-rose-950 text-rose-300 border border-rose-900",
                !@draining && "bg-emerald-950 text-emerald-300 border border-emerald-900"
              ]}
            >
              <span class={[
                "size-1.5 rounded-full",
                @draining && "bg-rose-400 animate-pulse",
                !@draining && "bg-emerald-400"
              ]} /> {@draining && "Дренаж активен — приём трафика закрыт"} {!@draining &&
                "Приём трафика открыт"}
            </span>
            <.admin_button phx-click="drain" kind="danger" disabled={@draining}>Drain</.admin_button>
            <.admin_button phx-click="reset_drain" kind="ghost" disabled={!@draining}>Reset</.admin_button>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-4 lg:grid-cols-4">
          <.stat_card
            label="Пользователи"
            value={to_string(@users_total)}
            navigate={~p"/admin/users"}
          />
          <.stat_card
            label="Онлайн"
            value={to_string(@online)}
            tone="ok"
            hint="Presence"
            navigate={~p"/admin/online"}
          />
          <.stat_card
            label="Комнат живых"
            value={to_string(@rooms)}
            navigate={~p"/admin/rooms"}
          />
          <.stat_card
            label="Клиентов в комнатах"
            value={to_string(@clients)}
            tone={(@draining && "danger") || "default"}
            navigate={~p"/admin/rooms"}
          />
        </div>

        <.panel
          title="Типы комнат"
          subtitle="Matchmaker.define_room: определено → живых комнат сейчас"
        >
          <.admin_table
            id="room-types"
            rows={@types}
            row_id={fn t -> "type-#{t.name}" end}
            empty="Комнатных типов не определено"
          >
            <:col :let={t} label="Тип">
              <span class="font-mono text-indigo-300">{t.name}</span>
            </:col>

            <:col :let={t} label="Живых комнат">
              <span class="tabular-nums">{t.live}</span>
            </:col>
          </.admin_table>

          <p :if={@unlisted > 0} class="mt-3 text-xs text-slate-500">
            ещё {@unlisted} комнат без типа (созданы по room_id, не публикуются в листинге)
          </p>
        </.panel>

        <.panel
          title="Метрики ноды"
          subtitle="Счётчики событий и gauge'и с последнего старта; полный снимок — раздел «Метрики»"
        >
          <.admin_table
            id="node-metrics"
            rows={@metrics}
            row_id={fn m -> "metric-#{m.name}" end}
            empty="Метрик пока нет"
          >
            <:col :let={m} label="Метрика">
              <span class="font-mono text-xs text-indigo-300">{m.name}</span>
            </:col>

            <:col :let={m} label="Значение">
              <span class="tabular-nums">{m.value}</span>
            </:col>
          </.admin_table>
        </.panel>
      </div>
    </Layouts.admin>
    """
  end
end
