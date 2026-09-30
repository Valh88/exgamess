defmodule ExGamesWebWeb.Admin.UserShowLive do
  @moduledoc "Профиль пользователя: роли, бан, сейвы, рейтинги; действия как в списке."

  use ExGamesWebWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {int_id, ""} <- Integer.parse(id),
         {:ok, user} <- ExGames.Account.fetch_user_by_id(int_id) do
      socket =
        socket
        |> assign(current_path: "/admin/users", page_title: "#{user.username} — ExGames Admin")
        |> assign(user: user)
        |> assign(roles: Enum.map(ExGames.Account.Role.builtin(), &Atom.to_string/1))
        |> assign(saves: ExGames.Account.list_saves(user.id))
        |> assign(ratings: ExGames.Account.user_ratings(user.id))
        |> assign(ban_form: nil)

      {:ok, socket}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Пользователь не найден")
         |> redirect(to: ~p"/admin/users")}
    end
  end

  @impl true
  def handle_event("ask_ban", _params, socket) do
    {:noreply, assign(socket, ban_form: to_form(%{"reason" => ""}, as: :ban))}
  end

  def handle_event("cancel_ban", _params, socket), do: {:noreply, assign(socket, ban_form: nil)}

  def handle_event("ban", %{"ban" => %{"reason" => reason}}, socket) do
    case ExGames.Account.ban(
           socket.assigns.user,
           if(reason != "", do: reason, else: "без причины")
         ) do
      {:ok, _banned} ->
        reload(socket, "забанен")

      {:error, errors} ->
        {:noreply, put_flash(socket, :error, inspect(errors))}
    end
  end

  def handle_event("unban", _params, socket) do
    case ExGames.Account.unban(socket.assigns.user) do
      {:ok, _user} -> reload(socket, "разбанен")
      _ -> {:noreply, put_flash(socket, :error, "Не удалось разбанить")}
    end
  end

  def handle_event("grant_role", %{"role" => role}, socket) when role != "" do
    case ExGames.Account.grant_role(socket.assigns.user, role) do
      {:ok, _role, _count} -> reload(socket, "выдана роль #{role}")
      _ -> {:noreply, put_flash(socket, :error, "Не удалось выдать роль")}
    end
  end

  def handle_event("grant_role", _params, socket), do: {:noreply, socket}

  def handle_event("revoke_role", %{"role" => role}, socket) do
    case ExGames.Account.revoke_role(socket.assigns.user, role) do
      :ok -> reload(socket, "снята роль #{role}")
      _ -> {:noreply, put_flash(socket, :error, "Не удалось снять роль")}
    end
  end

  defp reload(socket, message) do
    {:ok, user} = ExGames.Account.fetch_user_by_id(socket.assigns.user.id)

    {:noreply,
     socket
     |> assign(user: user)
     |> assign(saves: ExGames.Account.list_saves(user.id))
     |> assign(ratings: ExGames.Account.user_ratings(user.id))
     |> put_flash(:info, "#{user.username}: #{message}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} admin_user={@admin_user} current_path={@current_path}>
      <div class="space-y-6">
        <.link
          navigate={~p"/admin/users"}
          class="inline-flex items-center gap-1.5 text-sm text-slate-500 transition-colors hover:text-slate-300"
        >
          <.icon name="hero-arrow-left" class="size-4" /> Все пользователи
        </.link>

        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-xl font-semibold text-slate-100">{@user.username}</h1>
            <div class="mt-1.5 flex items-center gap-1.5">
              <.badge
                :for={r <- @user.roles}
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
              <.badge
                :if={@user.banned_at}
                tone="red"
                title={"Причина: #{@user.ban_reason || "не указана"}"}
              >
                забанен с {@user.banned_at |> Calendar.strftime("%d.%m.%Y")}
              </.badge>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <form phx-change="grant_role" id="grant-role-form" class="flex items-center">
              <select
                name="role"
                class="rounded-lg border border-slate-700 bg-slate-950 px-2 py-1.5 text-xs text-slate-200 focus:border-indigo-600 focus:outline-none"
              >
                <option value="">+ роль…</option>
                <option :for={r <- @roles} value={r}>{r}</option>
              </select>
            </form>
            <.admin_button :if={!@user.banned_at && !@ban_form} phx-click="ask_ban" kind="danger">
              Бан
            </.admin_button>
            <.admin_button :if={@user.banned_at} phx-click="unban">Разбанить</.admin_button>
          </div>
        </div>

        <.panel
          :if={@ban_form}
          title="Причина бана"
          subtitle="Пользователь не сможет войти (учётная запись сохраняется)"
          class="border-rose-900/70"
        >
          <.form for={@ban_form} id="ban-form" phx-submit="ban" class="flex gap-3">
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

        <.panel :if={@user.banned_at} title="Причина бана" class="border-rose-900/70">
          <p class="text-sm text-rose-200">{@user.ban_reason || "не указана"}</p>
        </.panel>

        <div class="grid gap-4 lg:grid-cols-2">
          <.panel title="Рейтинги" subtitle="Elo по играм">
            <.admin_table
              id="user-ratings"
              rows={@ratings}
              row_id={fn r -> "rating-#{r.game}" end}
              empty="Матчей не было"
            >
              <:col :let={r} label="Игра">
                <span class="font-mono text-indigo-300">{r.game}</span>
              </:col>
              <:col :let={r} label="Рейтинг">
                <span class="tabular-nums">{r.rating}</span>
              </:col>
              <:col :let={r} label="В/П/Н">
                <span class="tabular-nums">{r.wins}/{r.losses}/{r.draws}</span>
              </:col>
            </.admin_table>
          </.panel>

          <.panel title="Облачные сохранения" subtitle="Слоты без payload">
            <.admin_table
              id="user-saves"
              rows={@saves}
              row_id={fn s -> "save-#{s.key}" end}
              empty="Сейвов нет"
            >
              <:col :let={s} label="Ключ">
                <span class="font-mono text-indigo-300">{s.key}</span>
              </:col>
              <:col :let={s} label="Обновлён"><.datetime dt={s.updated_at} /></:col>
            </.admin_table>
          </.panel>
        </div>
      </div>
    </Layouts.admin>
    """
  end
end
