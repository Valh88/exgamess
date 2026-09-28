defmodule ExGamesWebWeb.AuthController do
  @moduledoc "REST: регистрация, вход, профиль."

  use ExGamesWebWeb, :controller

  action_fallback ExGamesWebWeb.FallbackController

  def register(conn, %{"username" => username, "password" => password}) do
    with {:ok, user} <-
           ExGames.Account.register(%{"username" => username, "password" => password}),
         {:ok, {:token, token, _}} <- ExGames.Account.login(username, password) do
      conn
      |> put_status(:created)
      |> json(%{"token" => token, "user" => ExGames.Account.User.to_wire(user)})
    end
  end

  def register(_conn, _params) do
    {:error, "expected username and password"}
  end

  def login(conn, %{"username" => username, "password" => password}) do
    with {:ok, {:token, token, user}} <- ExGames.Account.login(username, password) do
      json(conn, %{"token" => token, "user" => ExGames.Account.User.to_wire(user)})
    end
  end

  def login(_conn, _params) do
    {:error, "expected username and password"}
  end

  def me(conn, _params) do
    json(conn, %{"user" => ExGames.Account.User.to_wire(conn.assigns.current_user)})
  end
end
