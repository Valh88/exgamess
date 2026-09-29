defmodule ExGamesWebWeb.Admin.LoginLive do
  @moduledoc """
  Вход в админ-панель. Учётные данные — те же, что у игры
  (единая таблица users); дополнительное требование — роль `admin`.

  Сессию нельзя писать из LiveView (удалено в LV 1.x), поэтому форма
  через `phx-trigger-action` делает обычный POST на
  `AdminSessionController.create/2` — он проверяет логин, кладёт
  `admin_uid` в сессию (cookie-транспорт для браузера; игровые клиенты
  продолжают использовать Bearer) и перенаправляет в панель.
  """

  use ExGamesWebWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(current_path: nil, page_title: "Вход — ExGames Admin")
      |> assign(trigger: false)
      |> assign(form: to_form(%{"username" => "", "password" => ""}, as: :login))

    {:ok, socket}
  end

  @impl true
  def handle_event("login", _params, socket) do
    # базовая валидация на клиенте прошла — отдаём форму контроллеру
    {:noreply, assign(socket, trigger: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} bare>
      <div class="rounded-2xl border border-slate-800 bg-slate-900/70 p-8 shadow-2xl shadow-black/40">
        <div class="mb-6 text-center">
          <img src={~p"/images/logo.svg"} width="40" alt="" class="mx-auto" />
          <h1 class="mt-3 text-lg font-semibold text-slate-100">ExGames Admin</h1>
          <p class="mt-1 text-sm text-slate-500">Вход для администраторов</p>
        </div>

        <.form
          for={@form}
          id="admin-login-form"
          phx-submit="login"
          action={~p"/admin/login_session"}
          method="post"
          phx-trigger-action={@trigger}
          class="space-y-4"
        >
          <div>
            <label
              for="admin-username"
              class="mb-1 block text-xs uppercase tracking-wider text-slate-500"
            >
              Имя пользователя
            </label>
            <.input
              field={@form[:username]}
              id="admin-username"
              type="text"
              required
              autocomplete="username"
            />
          </div>

          <div>
            <label
              for="admin-password"
              class="mb-1 block text-xs uppercase tracking-wider text-slate-500"
            >
              Пароль
            </label>
            <.input
              field={@form[:password]}
              id="admin-password"
              type="password"
              required
              autocomplete="current-password"
            />
          </div>

          <button
            type="submit"
            class="w-full rounded-lg bg-indigo-600 py-2 text-sm font-medium text-white transition-colors hover:bg-indigo-500"
          >
            Войти
          </button>
        </.form>
      </div>
    </Layouts.admin>
    """
  end
end
