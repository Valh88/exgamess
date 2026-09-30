defmodule ExGamesWebWeb.Admin.OnlineLive do
  @moduledoc """
  Онлайн-присутствие: `Presence.list_online/0` + живые события
  join/leave (Presence.subscribe() → handle_diff-бродкасты).

  Контент зависит от `ExGames.Presence.track_user/2` — если игра не
  трекает пользователей, страница честно показывает пусто.
  """

  use ExGamesWebWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: ExGames.Presence.subscribe()

    socket =
      socket
      |> assign(current_path: "/admin/online", page_title: "Онлайн — ExGames Admin")

    {:ok, socket |> stream(:online, fetch())}
  end

  @impl true
  # join/leave-бродкасты из Presence.handle_diff
  def handle_info({ExGames.Presence, _diff}, socket) do
    {:noreply, socket |> stream(:online, fetch(), reset: true)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp fetch do
    ExGames.Presence.list_online()
    |> Enum.map(fn {user_id, meta} ->
      %{
        id: user_id,
        user_id: user_id,
        room_id: meta["room_id"],
        username: meta["username"]
      }
    end)
    |> Enum.sort_by(& &1.user_id)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} admin_user={@admin_user} current_path={@current_path}>
      <div class="space-y-6">
        <div>
          <h1 class="text-xl font-semibold text-slate-100">Онлайн</h1>
          <p class="text-sm text-slate-500">
            Пользователи, за которыми следит Presence (Phoenix.Tracker).
            Заполняется вызовами Presence.track_user/2 из игры.
          </p>
        </div>

        <.panel
          title="Подключённые пользователи"
          subtitle="обновляется вживую"
        >
          <.admin_table
            id="online-users"
            rows={@streams.online}
            row_id={fn {id, _u} -> id end}
            empty="Никого в онлайне — игра не вызывает track_user/2"
          >
            <:col :let={u} label="User ID">
              <span class="font-mono text-slate-300">{u.user_id}</span>
            </:col>
            <:col :let={u} label="Имя">{u.username || "—"}</:col>
            <:col :let={u} label="Комната">
              <.link
                :if={u.room_id}
                navigate={~p"/admin/rooms/#{u.room_id}"}
                class="font-mono text-indigo-300 hover:text-indigo-200"
              >
                {u.room_id}
              </.link>
              <span :if={!u.room_id} class="text-slate-600">—</span>
            </:col>
          </.admin_table>
        </.panel>
      </div>
    </Layouts.admin>
    """
  end
end
