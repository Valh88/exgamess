defmodule ExGamesWebWeb.Admin.RoomShowLive do
  @moduledoc """
  Детали комнаты: листинг, подключённые клиенты (session_id, user_id из auth,
  joined_at, RTT) со kick'ом и снапшот синхронизируемого состояния. Опрос 2 с.
  """

  use ExGamesWebWeb, :live_view

  @poll_ms 2000
  @snapshot_limit 20_000

  @impl true
  def mount(%{"id" => room_id}, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :poll, @poll_ms)

    socket =
      socket
      |> assign(current_path: "/admin/rooms", page_title: "Комната — ExGames Admin")
      |> assign(room_id: room_id, kick_confirm: nil)

    {:ok, refresh(socket)}
  end

  @impl true
  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_ms)

    {:noreply,
     socket |> refresh() |> stream(:clients, fetch_clients(socket.assigns.room_id), reset: true)}
  end

  @impl true
  def handle_event("kick", %{"sid" => sid}, socket) do
    ExGames.Room.kick(%ExGames.Room.Handle{room_id: socket.assigns.room_id}, sid)
    {:noreply, put_flash(socket, :info, "Клиент #{sid} кикнут")}
  end

  def handle_event("leave", _params, socket) do
    {:noreply, redirect(socket, to: ~p"/admin/rooms")}
  end

  defp refresh(socket) do
    room_id = socket.assigns.room_id

    listing =
      case ExGames.Room.Server.listing(room_id) do
        {:ok, listing} -> listing
        _ -> nil
      end

    if listing do
      {clients, _} = {fetch_clients(room_id), :ok}

      snapshot =
        case ExGames.Room.Server.state_snapshot(room_id) do
          {:ok, nil} -> nil
          {:ok, state} -> truncate(Jason.encode!(state, pretty: true))
          _ -> nil
        end

      socket
      |> assign(listing: listing)
      |> assign(snapshot: snapshot)
      |> stream(:clients, clients, reset: true)
    else
      # комната исчезла между опросами
      redirect(socket, to: ~p"/admin/rooms")
    end
  end

  defp fetch_clients(room_id) do
    case ExGames.Room.Server.clients_detailed(room_id) do
      {:ok, clients} ->
        Enum.map(Enum.sort_by(clients, & &1.session_id), fn c ->
          %{
            id: c.session_id,
            session_id: c.session_id,
            user_id: auth_user_id(c.auth),
            joined_at: c.joined_at,
            rtt: c.rtt,
            reconnect: !is_nil(c.reconnection_token)
          }
        end)

      _ ->
        []
    end
  end

  # auth — данные брони; веб-слой передаёт %{"user_id" => id}, прочие формы
  # показываем как есть
  defp auth_user_id(%{"user_id" => uid}), do: uid
  defp auth_user_id(%{user_id: uid}), do: uid
  defp auth_user_id(_), do: nil

  defp truncate(json) when byte_size(json) > @snapshot_limit do
    <<head::binary-size(@snapshot_limit), _rest::binary>> = json
    head <> "\n… (обрезано, полный документ см. в wire-кадрах)"
  end

  defp truncate(json), do: json

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} admin_user={@admin_user} current_path={@current_path}>
      <div class="space-y-6">
        <.link
          navigate={~p"/admin/rooms"}
          class="inline-flex items-center gap-1.5 text-sm text-slate-500 transition-colors hover:text-slate-300"
        >
          <.icon name="hero-arrow-left" class="size-4" /> Все комнаты
        </.link>

        <div class="flex items-center justify-between">
          <div>
            <h1 class="font-mono text-xl font-semibold text-indigo-300">{@room_id}</h1>
            <p class="text-sm text-slate-500">
              {@listing.module} · {@listing.clients}/{@listing.max_clients} клиентов ·
              создана {@listing.created_at |> Calendar.strftime("%d.%m.%Y %H:%M")}
            </p>
          </div>
          <.badge tone={(@listing.locked && "amber") || "green"}>
            {(@listing.locked && "закрыта") || "открыта"}
          </.badge>
        </div>

        <.panel title="Клиенты" subtitle="session_id · user_id (из auth) · вход · RTT">
          <.admin_table
            id="room-clients"
            rows={@streams.clients}
            row_id={fn {id, _c} -> id end}
            empty="Клиентов нет"
          >
            <:col :let={c} label="Session">
              <span class="font-mono text-xs text-slate-300">{c.session_id}</span>
            </:col>
            <:col :let={c} label="User ID">
              <span class="tabular-nums">{c.user_id || "—"}</span>
            </:col>
            <:col :let={c} label="Вошёл"><.datetime dt={c.joined_at} /></:col>
            <:col :let={c} label="RTT">
              <span class="tabular-nums">{(c.rtt && "#{c.rtt} мс") || "—"}</span>
            </:col>
            <:action :let={c}>
              <.admin_button phx-click="kick" phx-value-sid={c.session_id} kind="danger">
                Кик
              </.admin_button>
            </:action>
          </.admin_table>
        </.panel>

        <.panel
          title="Состояние (set_state)"
          subtitle="Снимок синхронизируемого wire-документа"
        >
          <pre
            :if={@snapshot}
            id="room-state-snapshot"
            phx-no-curly-interpolation
            class="max-h-96 overflow-auto rounded-lg border border-slate-800 bg-slate-950 p-4 font-mono text-xs leading-relaxed text-slate-300"
          >{@snapshot}</pre>
          <p :if={!@snapshot} id="room-state-empty" class="text-sm text-slate-500">
            Логика ещё не публиковала состояние (set_state).
          </p>
        </.panel>
      </div>
    </Layouts.admin>
    """
  end
end
