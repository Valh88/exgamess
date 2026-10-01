defmodule ExGamesWebWeb.Admin.RoomShowLive do
  @moduledoc """
  Детали комнаты: листинг, подключённые клиенты (session_id, user_id из auth,
  joined_at, RTT) со kick'ом, снапшот синхронизируемого состояния и форма
  «Установить состояние» — JSON-документ проходит валидацию по схеме логики
  (`ExGames.Room.StateSchema`) до отправки. Опрос 2 с.
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
      |> assign(set_state_text: nil)

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

  def handle_event("set_state_change", %{"set_state" => %{"doc" => text}}, socket) do
    {:noreply, assign(socket, set_state_text: text)}
  end

  def handle_event("set_state", %{"set_state" => %{"doc" => text}}, socket) do
    room_id = socket.assigns.room_id

    with {:json, {:ok, doc}} when is_map(doc) <- {:json, Jason.decode(text)},
         {:schemas, {:ok, schemas}} <-
           {:schemas, ExGames.Room.Server.state_schemas(room_id)},
         :ok <- ExGames.Room.StateSchema.validate_root(schemas, doc) do
      ExGames.Room.set_state(%ExGames.Room.Handle{room_id: room_id}, doc)
      {:noreply, put_flash(socket, :info, "Состояние отправлено в комнату")}
    else
      {:json, _} ->
        {:noreply, put_flash(socket, :error, "Некорректный JSON (нужен объект)")}

      {:schemas, _} ->
        {:noreply, put_flash(socket, :error, "Комната недоступна")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Схема состояния отклонила документ: " <> reason)}
    end
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

      snapshot_json =
        case ExGames.Room.Server.state_snapshot(room_id) do
          {:ok, nil} -> nil
          {:ok, state} -> Jason.encode!(state, pretty: true)
          _ -> nil
        end

      schemas =
        case ExGames.Room.Server.state_schemas(room_id) do
          {:ok, schemas} -> schemas
          _ -> %{}
        end

      socket =
        socket
        |> assign(listing: listing)
        |> assign(snapshot: snapshot_json && truncate(snapshot_json))
        |> assign(schemas: schemas)
        |> stream(:clients, clients, reset: true)

      # полный (необрезанный) JSON — редактировать обрезанный нельзя;
      # ввод пользователя (set_state_change) не затирается
      if is_nil(socket.assigns.set_state_text) && snapshot_json &&
           byte_size(snapshot_json) <= @snapshot_limit do
        assign(socket, set_state_text: snapshot_json)
      else
        socket
      end
    else
      # комната исчезла между опросами
      redirect(socket, to: ~p"/admin/rooms")
    end
  end

  defp set_state_form, do: to_form(%{}, as: :set_state)

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
          
          <details :if={map_size(@schemas) > 0} class="mt-3" id="room-state-schema-details">
            <summary class="cursor-pointer select-none text-xs text-slate-500 transition-colors hover:text-slate-300">
              Схема состояния логики (M.schema)
            </summary>
             <pre
              id="room-state-schema"
              phx-no-curly-interpolation
              class="mt-2 max-h-60 overflow-auto rounded-lg border border-slate-800 bg-slate-950 p-3 font-mono text-xs leading-relaxed text-slate-400"
            >{Jason.encode!(@schemas, pretty: true)}</pre>
          </details>
          
          <div class="mt-4 border-t border-slate-800 pt-4" id="set-state-block">
            <h3 class="text-sm font-medium text-slate-200">Установить состояние</h3>
            
            <p class="mt-1 text-xs text-slate-500">
              JSON-документ; проверяется по схеме логики до отправки, отклонённый — не применяется.
            </p>
            
            <.form
              for={set_state_form()}
              id="set-state-form"
              phx-change="set_state_change"
              phx-submit="set_state"
              class="mt-3"
            >
              <.input
                field={set_state_form()[:doc]}
                id="set-state-doc"
                type="textarea"
                rows="10"
                value={@set_state_text}
                class="w-full rounded-lg border border-slate-700 bg-slate-950 p-3 font-mono text-xs leading-relaxed text-slate-200 transition-colors focus:border-indigo-500 focus:outline-none"
                spellcheck="false"
              /> <.admin_button kind="primary" type="submit">Применить</.admin_button>
            </.form>
          </div>
        </.panel>
      </div>
    </Layouts.admin>
    """
  end
end
