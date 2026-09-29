defmodule ExGamesWebWeb.Admin.RoomIndexLive do
  @moduledoc """
  Живые комнаты: листинг матчмейкера + enriched-данные Room.Server.
  Обновления — подписка на лобби-топик PubSub (`{:ex_games, :lobby, …}`)
  плюс периодический refetch. Действия: lock/unlock, dispose (с подтверждением).
  """

  use ExGamesWebWeb, :live_view

  @poll_ms 5000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ExGames.PubSub, ExGames.Matchmaker.lobby_topic())
      Process.send_after(self(), :poll, @poll_ms)
    end

    socket =
      socket
      |> assign(current_path: "/admin/rooms", page_title: "Комнаты — ExGames Admin")
      |> assign(confirm_dispose: nil)

    {:ok, socket |> stream(:rooms, fetch())}
  end

  @impl true
  def handle_info({:ex_games, :lobby, _change}, socket) do
    {:noreply, socket |> stream(:rooms, fetch(), reset: true)}
  end

  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, socket |> stream(:rooms, fetch(), reset: true)}
  end

  @impl true
  def handle_event("lock", %{"id" => room_id}, socket) do
    ExGames.Room.lock(%ExGames.Room.Handle{room_id: room_id})
    {:noreply, socket |> stream(:rooms, fetch(), reset: true)}
  end

  def handle_event("unlock", %{"id" => room_id}, socket) do
    ExGames.Room.unlock(%ExGames.Room.Handle{room_id: room_id})
    {:noreply, socket |> stream(:rooms, fetch(), reset: true)}
  end

  def handle_event("ask_dispose", %{"id" => room_id}, socket) do
    # parent-assign внутри stream-строк требует пере-стрима элементов
    # (см. AGENTS.md: assign, влияющий на содержимое stream-строк)
    {:noreply,
     socket
     |> assign(confirm_dispose: room_id)
     |> stream(:rooms, fetch(), reset: true)}
  end

  def handle_event("cancel_dispose", _params, socket) do
    {:noreply,
     socket
     |> assign(confirm_dispose: nil)
     |> stream(:rooms, fetch(), reset: true)}
  end

  def handle_event("dispose", %{"id" => room_id}, socket) do
    ExGames.Rooms.stop(room_id)

    {:noreply,
     socket
     |> assign(confirm_dispose: nil)
     |> stream(:rooms, fetch(), reset: true)
     |> put_flash(:info, "Комната #{room_id} закрыта")}
  end

  # -------------------------------------------------------------------------

  defp fetch do
    now = DateTime.utc_now()

    for listing <- ExGames.Matchmaker.all_listings() do
      details =
        case ExGames.Room.Server.listing(listing.room_id) do
          {:ok, details} -> details
          _ -> %{}
        end

      created_at = details[:created_at]

      %{
        id: listing.room_id,
        room_id: listing.room_id,
        name: listing.room_name || "(без типа)",
        clients: listing.clients,
        max_clients: listing.max_clients,
        locked: listing.locked,
        metadata: listing.metadata,
        module: details[:module],
        created_at: created_at,
        age: created_at && format_age(DateTime.diff(now, created_at))
      }
    end
    |> Enum.sort_by(& &1.room_id)
  end

  defp format_age(seconds) when seconds < 60, do: "#{seconds}с"

  defp format_age(seconds) when seconds < 3600, do: "#{div(seconds, 60)}м #{rem(seconds, 60)}с"

  defp format_age(seconds) when seconds < 86_400,
    do: "#{div(seconds, 3600)}ч #{div(rem(seconds, 3600), 60)}м"

  defp format_age(seconds), do: "#{div(seconds, 86_400)}д"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} admin_user={@admin_user} current_path={@current_path}>
      <div class="space-y-6">
      <div>
        <h1 class="text-xl font-semibold text-slate-100">Комнаты</h1>
        <p class="text-sm text-slate-500">
          Живые комнаты; обновляется по лобби-топику и опросом. Комнаты без типа
          (созданные по room_id) не видны в листинге матчмейкера.
        </p>
      </div>

      <.panel>
        <.admin_table
          id="rooms"
          rows={@streams.rooms}
          row_id={fn {id, _r} -> id end}
          empty="Живых комнат нет"
        >
          <:col :let={r} label="Комната">
            <.link
              navigate={~p"/admin/rooms/#{r.room_id}"}
              class="font-mono text-indigo-300 transition-colors hover:text-indigo-200"
            >
              {r.room_id}
            </.link>
          </:col>
          <:col :let={r} label="Тип"><span class="text-slate-300">{r.name}</span></:col>
          <:col :let={r} label="Клиенты">
            <span class="tabular-nums">{r.clients}/{r.max_clients}</span>
          </:col>
          <:col :let={r} label="Статус">
            <.badge :if={r.locked} tone="amber">закрыта</.badge>
            <.badge :if={!r.locked} tone="green">открыта</.badge>
          </:col>
          <:col :let={r} label="Возраст">{r.age || "—"}</:col>
          <:col :let={r} label="Метаданные">
            <code class="text-xs text-slate-400">
              {(r.metadata == %{} && "—") || inspect(r.metadata, limit: 3)}
            </code>
          </:col>
          <:action :let={r}>
            <div class="flex flex-wrap items-center justify-end gap-2">
              <.admin_button
                :if={!r.locked}
                phx-click="lock"
                phx-value-id={r.room_id}
                kind="ghost"
                title="Закрыть для новых клиентов"
              >
                Lock
              </.admin_button>
              <.admin_button
                :if={r.locked}
                phx-click="unlock"
                phx-value-id={r.room_id}
                kind="ghost"
                title="Открыть для новых клиентов"
              >
                Unlock
              </.admin_button>
              <.admin_button
                :if={@confirm_dispose == r.room_id}
                phx-click="cancel_dispose"
                kind="ghost"
              >
                Отмена
              </.admin_button>
              <.admin_button
                :if={@confirm_dispose == r.room_id}
                phx-click="dispose"
                phx-value-id={r.room_id}
                kind="danger"
              >
                Точно закрыть
              </.admin_button>
              <.admin_button
                :if={@confirm_dispose != r.room_id}
                phx-click="ask_dispose"
                phx-value-id={r.room_id}
                kind="danger"
              >
                Dispose
              </.admin_button>
            </div>
          </:action>
        </.admin_table>
      </.panel>
    </div>
    </Layouts.admin>
    """
  end
end
