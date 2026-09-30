defmodule ExGamesWebWeb.Admin.RoomIndexLive do
  @moduledoc """
  Живые комнаты: листинг матчмейкера + enriched-данные Room.Server.
  Обновления — подписка на лобби-топик PubSub (`{:ex_games, :lobby, …}`)
  плюс периодический refetch.

  Фильтры (поиск по room_id, тип, статус) и пагинация считаются по
  листингам — это чтение ETS без вызовов комнат; GenServer-вызовы за
  деталями (модуль, время создания) идут только для видимой страницы.
  Действия: lock/unlock, dispose (с подтверждением).
  """

  use ExGamesWebWeb, :live_view

  @page_size 25
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
      |> assign(search: "", type: "", status: "", page: 1)
      |> assign(filter_form: to_form(%{}, as: :filter))

    {entries, meta, types} = fetch(socket.assigns)

    {:ok,
     socket
     |> assign(meta: meta, room_types: types)
     |> stream(:rooms, entries)}
  end

  @impl true
  def handle_info({:ex_games, :lobby, _change}, socket), do: {:noreply, refetch(socket)}

  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, refetch(socket)}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    socket =
      assign(socket,
        search: filter["search"] || "",
        type: filter["type"] || "",
        status: filter["status"] || "",
        page: 1
      )

    {:noreply, refetch(socket)}
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  def handle_event("next_page", _params, socket) do
    %{page: page, page_size: size, total: total} = socket.assigns.meta

    if page * size < total do
      {:noreply, socket |> assign(page: page + 1) |> refetch()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("prev_page", _params, socket) when socket.assigns.page > 1 do
    {:noreply, socket |> assign(page: socket.assigns.page - 1) |> refetch()}
  end

  def handle_event("prev_page", _params, socket), do: {:noreply, socket}

  def handle_event("lock", %{"id" => room_id}, socket) do
    ExGames.Room.lock(%ExGames.Room.Handle{room_id: room_id})
    {:noreply, refetch(socket)}
  end

  def handle_event("unlock", %{"id" => room_id}, socket) do
    ExGames.Room.unlock(%ExGames.Room.Handle{room_id: room_id})
    {:noreply, refetch(socket)}
  end

  def handle_event("ask_dispose", %{"id" => room_id}, socket) do
    # parent-assign внутри stream-строк требует пере-стрима элементов
    # (см. AGENTS.md: assign, влияющий на содержимое stream-строк)
    {:noreply,
     socket
     |> assign(confirm_dispose: room_id)
     |> refetch()}
  end

  def handle_event("cancel_dispose", _params, socket),
    do: {:noreply, socket |> assign(confirm_dispose: nil) |> refetch()}

  def handle_event("dispose", %{"id" => room_id}, socket) do
    ExGames.Rooms.stop(room_id)

    {:noreply,
     socket
     |> assign(confirm_dispose: nil)
     |> refetch()
     |> put_flash(:info, "Комната #{room_id} закрыта")}
  end

  # -------------------------------------------------------------------------

  defp refetch(socket) do
    {entries, meta, types} = fetch(socket.assigns)
    socket |> assign(meta: meta, room_types: types) |> stream(:rooms, entries, reset: true)
  end

  defp fetch(assigns) do
    listings = ExGames.Matchmaker.all_listings()
    types = listings |> MapSet.new(& &1.room_name) |> Enum.sort()

    filtered =
      listings
      |> filter_search(assigns.search)
      |> filter_type(assigns.type)
      |> filter_status(assigns.status)
      |> Enum.sort_by(& &1.room_id)

    pages = max(div(length(filtered) + @page_size - 1, @page_size), 1)
    page = min(assigns.page, pages)

    meta = %{total: length(filtered), page: page, page_size: @page_size, pages: pages}

    entries =
      filtered
      |> Enum.slice((page - 1) * @page_size, @page_size)
      |> Enum.map(&enrich/1)

    {entries, meta, types}
  end

  defp filter_search(listings, search) do
    if search == "",
      do: listings,
      else: Enum.filter(listings, &String.contains?(&1.room_id, search))
  end

  defp filter_type(listings, type) do
    if type == "", do: listings, else: Enum.filter(listings, &(&1.room_name == type))
  end

  defp filter_status(listings, "open"), do: Enum.filter(listings, &(!&1.locked))
  defp filter_status(listings, "locked"), do: Enum.filter(listings, & &1.locked)
  defp filter_status(listings, _), do: listings

  defp enrich(listing) do
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
      age: created_at && format_age(DateTime.diff(DateTime.utc_now(), created_at))
    }
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
            {@meta.total} всего · страница {@meta.page} из {@meta.pages} · обновляется
            по лобби-топику и опросом. Комнаты без типа (созданные по room_id)
            не видны в листинге матчмейкера.
          </p>
        </div>

        <.panel>
          <.form
            for={@filter_form}
            id="room-filters"
            phx-change="filter"
            class="mb-4 flex flex-wrap items-end gap-3"
          >
            <div>
              <label class="mb-1 block text-xs uppercase tracking-wider text-slate-500">Поиск</label>
              <.input
                field={@filter_form[:search]}
                type="text"
                placeholder="room_id…"
                phx-debounce="300"
                class="w-48 rounded-lg border border-slate-700 bg-slate-950 px-3 py-1.5 text-sm text-slate-200 placeholder:text-slate-600 focus:border-indigo-600 focus:outline-none"
              />
            </div>
            <div>
              <label class="mb-1 block text-xs uppercase tracking-wider text-slate-500">Тип</label>
              <.input
                field={@filter_form[:type]}
                type="select"
                options={[{"все типы", ""} | Enum.map(@room_types, &{&1, &1})]}
                class="w-44 rounded-lg border border-slate-700 bg-slate-950 px-3 py-1.5 text-sm text-slate-200 focus:border-indigo-600 focus:outline-none"
              />
            </div>
            <div>
              <label class="mb-1 block text-xs uppercase tracking-wider text-slate-500">Статус</label>
              <.input
                field={@filter_form[:status]}
                type="select"
                options={[{"все", ""}, {"открытые", "open"}, {"закрытые", "locked"}]}
                class="w-40 rounded-lg border border-slate-700 bg-slate-950 px-3 py-1.5 text-sm text-slate-200 focus:border-indigo-600 focus:outline-none"
              />
            </div>
          </.form>

          <.admin_table
            id="rooms"
            rows={@streams.rooms}
            row_id={fn {id, _r} -> id end}
            empty="Живых комнат нет"
            fixed
            min_w="860px"
          >
            <:col :let={r} label="Комната" class="w-48">
              <div class="truncate">
                <.link
                  navigate={~p"/admin/rooms/#{r.room_id}"}
                  class="font-mono text-indigo-300 transition-colors hover:text-indigo-200"
                >
                  {r.room_id}
                </.link>
              </div>
            </:col>
            <:col :let={r} label="Тип" class="w-40">
              <span class="truncate text-slate-300">{r.name}</span>
            </:col>
            <:col :let={r} label="Клиенты" class="w-24">
              <span class="tabular-nums">{r.clients}/{r.max_clients}</span>
            </:col>
            <:col :let={r} label="Статус" class="w-28">
              <.badge :if={r.locked} tone="amber">закрыта</.badge>
              <.badge :if={!r.locked} tone="green">открыта</.badge>
            </:col>
            <:col :let={r} label="Возраст" class="w-28">{r.age || "—"}</:col>
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

          <div class="mt-4 flex items-center justify-end gap-2">
            <.admin_button phx-click="prev_page" disabled={@meta.page <= 1}>← Назад</.admin_button>
            <.admin_button
              phx-click="next_page"
              disabled={@meta.page * @meta.page_size >= @meta.total}
            >
              Вперёд →
            </.admin_button>
          </div>
        </.panel>
      </div>
    </Layouts.admin>
    """
  end
end
