defmodule ExGamesWebWeb.Admin.Auth do
  @moduledoc """
  on_mount-гвард админ-панели: сессия → пользователь → роль `admin`.

  Транспорт auth — cookie-сессия (браузерные страницы); сами учётные
  данные те же, что у игры (`Account.login/2`, одна таблица users).
  Проверка выполняется на каждый mount: бан/снятие роли «на лету»
  закрывает доступ при следующей навигации.

      live_session :admin, on_mount: [{ExGamesWebWeb.Admin.Auth, :ensure_admin}]
  """

  import Phoenix.LiveView
  import Phoenix.Component
  use ExGamesWebWeb, :verified_routes

  def on_mount(:ensure_admin, _params, session, socket) do
    case current_admin(session) do
      {:ok, user} ->
        {:cont, assign(socket, :admin_user, user)}

      :error ->
        {:halt, redirect(socket, to: ~p"/admin/login")}
    end
  end

  @doc "Разбирает сессию: {:ok, user} если это живой администратор."
  @spec current_admin(map()) :: {:ok, ExGames.Account.User.t()} | :error
  def current_admin(session) when is_map(session) do
    with uid when is_integer(uid) <- session["admin_uid"],
         {:ok, user} <- ExGames.Account.fetch_user_by_id(uid),
         true <- ExGames.Account.has_role?(user, :admin),
         %{} = user <- alive?(user) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp alive?(%{banned_at: nil} = user), do: user
  defp alive?(_), do: nil
end
