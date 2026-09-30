defmodule ExGamesWebWeb.Admin.UserIndexLive do
  @moduledoc """
  Управление пользователями: поиск, фильтры (роль/бан), пагинация;
  бан (с причиной) / разбан, выдача и снятие ролей. Коллекция — stream.
  """

  use ExGamesWebWeb, :live_view

  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(current_path: "/admin/users", page_title: "Пользователи — ExGames Admin")
      |> assign(search: "", role: "", banned: "", page: 1)
      |> assign(roles: Enum.map(ExGames.Account.Role.builtin(), &Atom.to_string/1))
      |> assign(ban_user: nil, ban_form: nil)
      |> assign(filter_form: to_form(%{}, as: :filter))

    {entries, meta} = fetch(socket.assigns)
    {:ok, socket |> assign(meta: meta) |> stream(:users, entries)}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    socket =
      assign(socket,
        search: filter["search"] || "",
        role: filter["role"] || "",
        banned: filter["banned"] || "",
        page: 1
      )

    {entries, meta} = fetch(socket.assigns)
    {:noreply, socket |> assign(meta: meta) |> stream(:users, entries, reset: true)}
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  def handle_event("next_page", _params, socket) do
    %{page: page, page_size: size, total: total} = socket.assigns.meta

    if page * size < total do
      socket = assign(socket, page: page + 1)
      {entries, meta} = fetch(socket.assigns)
      {:noreply, socket |> assign(meta: meta) |> stream(:users, entries, reset: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("prev_page", _params, socket) when socket.assigns.page > 1 do
    socket = assign(socket, page: socket.assigns.page - 1)
    {entries, meta} = fetch(socket.assigns)
    {:noreply, socket |> assign(meta: meta) |> stream(:users, entries, reset: true)}
  end

  def handle_event("prev_page", _params, socket), do: {:noreply, socket}

  def handle_event("ask_ban", %{"id" => id}, socket) do
    with {:ok, user} <- ExGames.Account.fetch_user_by_id(String.to_integer(id)) do
      {:noreply, assign(socket, ban_user: user, ban_form: to_form(%{"reason" => ""}, as: :ban))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Пользователь не найден")}
    end
  end

  def handle_event("cancel_ban", _params, socket),
    do: {:noreply, assign(socket, ban_user: nil, ban_form: nil)}

  # страховка: submit формы мог прийти после cancel_ban (гонка двух событий)
  def handle_event("confirm_ban", _params, %{assigns: %{ban_user: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_ban", %{"ban" => %{"reason" => reason}}, socket) do
    user = socket.assigns.ban_user

    case ExGames.Account.ban(user, if(reason != "", do: reason, else: "без причины")) do
      {:ok, _banned} ->
        socket =
          socket
          |> assign(ban_user: nil, ban_form: nil)
          |> put_flash(:info, "#{user.username} забанен")

        {entries, meta} = fetch(socket.assigns)
        {:noreply, socket |> assign(meta: meta) |> stream(:users, entries, reset: true)}

      {:error, errors} ->
        {:noreply, put_flash(socket, :error, format_errors(errors))}
    end
  end

  def handle_event("unban", %{"id" => id}, socket) do
    with {:ok, user} <- ExGames.Account.fetch_user_by_id(String.to_integer(id)),
         {:ok, _user} <- ExGames.Account.unban(user) do
      socket = put_flash(socket, :info, "#{user.username} разбанен")
      {entries, meta} = fetch(socket.assigns)
      {:noreply, socket |> assign(meta: meta) |> stream(:users, entries, reset: true)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Не удалось разбанить")}
    end
  end

  def handle_event("grant_role", %{"id" => id, "role" => role}, socket) when role != "" do
    with {:ok, user} <- ExGames.Account.fetch_user_by_id(String.to_integer(id)),
         {:ok, _role, _count} <- ExGames.Account.grant_role(user, role) do
      socket = put_flash(socket, :info, "#{user.username}: выдана роль #{role}")
      {entries, meta} = fetch(socket.assigns)
      {:noreply, socket |> assign(meta: meta) |> stream(:users, entries, reset: true)}
    else
      {:error, errors} when is_map(errors) ->
        {:noreply, put_flash(socket, :error, format_errors(errors))}

      _ ->
        {:noreply, put_flash(socket, :error, "Не удалось выдать роль")}
    end
  end

  def handle_event("grant_role", _params, socket), do: {:noreply, socket}

  def handle_event("revoke_role", %{"id" => id, "role" => role}, socket) do
    with {:ok, user} <- ExGames.Account.fetch_user_by_id(String.to_integer(id)),
         :ok <- ExGames.Account.revoke_role(user, role) do
      socket = put_flash(socket, :info, "#{user.username}: снята роль #{role}")
      {entries, meta} = fetch(socket.assigns)
      {:noreply, socket |> assign(meta: meta) |> stream(:users, entries, reset: true)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Не удалось снять роль")}
    end
  end

  # -------------------------------------------------------------------------

  defp fetch(assigns) do
    listing =
      ExGames.Account.list_users(
        search: present(assigns.search),
        role: present(assigns.role),
        banned: parse_banned(assigns.banned),
        page: assigns.page,
        page_size: @page_size
      )

    entries = listing.entries

    meta = %{
      total: listing.total,
      page: listing.page,
      page_size: listing.page_size,
      pages: max(div(listing.total + listing.page_size - 1, listing.page_size), 1)
    }

    {entries, meta}
  end

  defp present(""), do: nil
  defp present(value), do: value

  defp parse_banned("true"), do: true
  defp parse_banned("false"), do: false
  defp parse_banned(_), do: nil

  defp format_errors(errors) when is_map(errors) do
    Enum.map_join(errors, "; ", fn {k, v} -> "#{k}: #{Enum.join(List.wrap(v), ", ")}" end)
  end

  defp format_errors(other), do: inspect(other)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} admin_user={@admin_user} current_path={@current_path}>
      <div class="space-y-6">
        <div>
          <h1 class="text-xl font-semibold text-slate-100">Пользователи</h1>
          <p class="text-sm text-slate-500">
            {@meta.total} всего · страница {@meta.page} из {@meta.pages}
          </p>
        </div>

        <.panel
          :if={@ban_user}
          title={"Бан: " <> @ban_user.username}
          subtitle="Пользователь не сможет войти (учётная запись сохраняется)"
          class="border-rose-900/70"
        >
          <.form
            for={@ban_form}
            id="ban-form"
            phx-submit="confirm_ban"
            class="flex flex-col gap-3 sm:flex-row sm:items-center"
          >
            <.input
              field={@ban_form[:reason]}
              type="text"
              placeholder="Причина бана"
              class="flex-1 rounded-lg border border-slate-700 bg-slate-950 px-3 py-1.5 text-sm text-slate-200 placeholder:text-slate-600 focus:border-indigo-600 focus:outline-none"
            />
            <.admin_button phx-click="cancel_ban" kind="ghost">Отмена</.admin_button>
            <.admin_button type="submit" kind="danger">Забанить</.admin_button>
          </.form>
        </.panel>

        <.panel>
          <.form
            for={@filter_form}
            id="user-filters"
            phx-change="filter"
            class="mb-4 flex flex-wrap items-end gap-3"
          >
            <div>
              <label class="mb-1 block text-xs uppercase tracking-wider text-slate-500">Поиск</label>
              <.input
                field={@filter_form[:search]}
                type="text"
                placeholder="username…"
                phx-debounce="300"
                class="w-48 rounded-lg border border-slate-700 bg-slate-950 px-3 py-1.5 text-sm text-slate-200 placeholder:text-slate-600 focus:border-indigo-600 focus:outline-none"
              />
            </div>
            <div>
              <label class="mb-1 block text-xs uppercase tracking-wider text-slate-500">Роль</label>
              <.input
                field={@filter_form[:role]}
                type="select"
                options={[{"все роли", ""} | Enum.map(@roles, &{&1, &1})]}
                class="w-40 rounded-lg border border-slate-700 bg-slate-950 px-3 py-1.5 text-sm text-slate-200 focus:border-indigo-600 focus:outline-none"
              />
            </div>
            <div>
              <label class="mb-1 block text-xs uppercase tracking-wider text-slate-500">Статус</label>
              <.input
                field={@filter_form[:banned]}
                type="select"
                options={[{"все", ""}, {"забаненные", "true"}, {"активные", "false"}]}
                class="w-40 rounded-lg border border-slate-700 bg-slate-950 px-3 py-1.5 text-sm text-slate-200 focus:border-indigo-600 focus:outline-none"
              />
            </div>
          </.form>

          <.admin_table
            id="users"
            rows={@streams.users}
            row_id={fn {id, _u} -> id end}
            empty="Никого не найдено"
            fixed
            min_w="760px"
          >
            <:col :let={u} label="Пользователь" class="w-52">
              <div class="truncate">
                <.link
                  navigate={~p"/admin/users/#{u.id}"}
                  class="font-medium text-indigo-300 transition-colors hover:text-indigo-200"
                >
                  {u.username}
                </.link>
              </div>
            </:col>
            <:col :let={u} label="Роли" class="w-44">
              <div class="flex flex-wrap gap-1">
                <.badge
                  :for={r <- u.roles}
                  tone={
                    cond do
                      r.name == "admin" -> "indigo"
                      r.name == "moderator" -> "amber"
                      true -> "slate"
                    end
                  }
                >
                  {r.name}
                </.badge>
                <span :if={u.roles == []} class="text-slate-600">—</span>
              </div>
            </:col>
            <:col :let={u} label="Статус" class="w-44">
              <span :if={u.banned_at} title={"Причина: #{u.ban_reason || "не указана"}"}>
                <.badge tone="red" title={"Причина: #{u.ban_reason || "не указана"}"}>
                  бан с {format_date(u.banned_at)}
                </.badge>
              </span>
              <.badge :if={!u.banned_at} tone="green">активен</.badge>
            </:col>
            <:action :let={u}>
              <div class="flex flex-wrap items-center justify-end gap-2">
                <.admin_button
                  :if={!u.banned_at}
                  phx-click="ask_ban"
                  phx-value-id={u.id}
                  kind="danger"
                >
                  Бан
                </.admin_button>
                <.admin_button :if={u.banned_at} phx-click="unban" phx-value-id={u.id}>
                  Разбанить
                </.admin_button>
                <form
                  phx-change="grant_role"
                  phx-value-id={u.id}
                  id={"grant-role-#{u.id}"}
                  class="flex items-center"
                >
                  <select
                    name="role"
                    class="rounded-lg border border-slate-700 bg-slate-950 px-2 py-1.5 text-xs text-slate-200 transition-colors hover:border-slate-600 focus:border-indigo-600 focus:outline-none"
                  >
                    <option value="">+ роль…</option>
                    <option :for={r <- @roles} value={r}>{r}</option>
                  </select>
                </form>
                <.admin_button
                  :for={r <- u.roles}
                  phx-click="revoke_role"
                  phx-value-id={u.id}
                  phx-value-role={r.name}
                  kind="ghost"
                  title={"Снять роль #{r.name}"}
                >
                  − {r.name}
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

  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%d.%m.%Y")
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%d.%m.%Y")
  defp format_date(_), do: "?"
end
