defmodule ExGamesWebWeb.AdminSessionController do
  @moduledoc """
  Сессия админ-панели: вход (POST из LoginLive через phx-trigger-action)
  и выход. Учётные данные те же, что у игры; в сессию кладётся `admin_uid`.
  """

  use ExGamesWebWeb, :controller

  def create(conn, %{"login" => %{"username" => username, "password" => password}}) do
    case ExGames.Account.login(username, password) do
      {:ok, {:token, _token, user}} ->
        if ExGames.Account.has_role?(user, :admin) do
          conn
          |> put_session(:admin_uid, user.id)
          |> put_flash(:info, "Добро пожаловать, #{user.username}!")
          |> redirect(to: ~p"/admin")
        else
          conn
          |> put_flash(:error, "Недостаточно прав: требуется роль admin")
          |> redirect(to: ~p"/admin/login")
        end

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Неверное имя пользователя или пароль")
        |> redirect(to: ~p"/admin/login")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Укажите имя пользователя и пароль")
    |> redirect(to: ~p"/admin/login")
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> put_flash(:info, "Вы вышли из админ-панели")
    |> redirect(to: ~p"/admin/login")
  end
end
