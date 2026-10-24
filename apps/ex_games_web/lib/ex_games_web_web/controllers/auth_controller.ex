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

  @doc """
  Живые сессии пользователя: комнаты, где он онлайн (по presence), с типом
  комнаты из листинга матчмейкера. Для экрана «вернуться в матч?» после
  перезапуска приложения (восстановление — `POST /api/matchmake/resume/:room_id`).
  """
  def sessions(conn, _params) do
    user_id =
      conn.assigns.current_user.id
      |> to_string()

    room_names =
      ExGames.Matchmaker.all_listings()
      |> Map.new(fn listing -> {listing.room_id, listing.room_name} end)

    sessions =
      ExGames.Presence.list_online_entries()
      |> Enum.filter(fn {{uid, _room_id}, _meta} -> uid == user_id end)
      |> Enum.map(fn {{_uid, room_id}, meta} ->
        %{
          "room_id" => room_id,
          "room_name" => Map.get(room_names, room_id),
          "username" => Map.get(meta, "username")
        }
      end)

    json(conn, %{"sessions" => sessions})
  end
end
