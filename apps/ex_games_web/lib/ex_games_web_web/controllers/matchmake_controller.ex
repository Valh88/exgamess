defmodule ExGamesWebWeb.MatchmakeController do
  @moduledoc """
  REST-фасад матчмейкера (шаг 1 двухфазного join):

      POST /matchmake/:method/:room_name
      methods: join_or_create | create | join

  Ответ — seat reservation:

      {"room_name": "arena", "room_id": "abc123def", "session_id": "s456..."}

  Клиент затем открывает WS `/ws/:room_id?sessionId=:session_id`.
  Опции (фильтры и т.п.) передаются в JSON-теле.
  """

  use ExGamesWebWeb, :controller

  action_fallback ExGamesWebWeb.FallbackController

  def matchmake(conn, %{"method" => "join_or_create", "room_name" => name}) do
    with {:ok, res} <- ExGames.Matchmaker.join_or_create(name, auth_data(conn), options(conn)) do
      json(conn, ExGames.Matchmaker.Reservation.to_wire(res))
    end
  end

  def matchmake(conn, %{"method" => "create", "room_name" => name}) do
    with {:ok, res} <- ExGames.Matchmaker.create(name, auth_data(conn), options(conn)) do
      json(conn, ExGames.Matchmaker.Reservation.to_wire(res))
    end
  end

  def matchmake(conn, %{"method" => "join", "room_name" => name}) do
    with {:ok, res} <- ExGames.Matchmaker.join(name, auth_data(conn), options(conn)) do
      json(conn, ExGames.Matchmaker.Reservation.to_wire(res))
    end
  end

  def matchmake(_conn, %{"method" => method}) do
    {:error, "unknown matchmake method: #{method}"}
  end

  @doc "Join по конкретному room_id (без поиска по типу комнаты)."
  def join_by_id(conn, %{"room_id" => room_id}) do
    with {:ok, res} <- ExGames.Matchmaker.join_by_id(room_id, auth_data(conn), options(conn)) do
      json(conn, ExGames.Matchmaker.Reservation.to_wire(res))
    end
  end

  @doc """
  Шаг 1 reconnect-флоу: проверка reconnection-токена после обрыва.
  Возвращает `session_id` для подключения `WS /ws/:room_id?sessionId=…&reconnectionToken=…`.
  """
  def reconnect(conn, %{"room_id" => room_id, "reconnection_token" => token} = params) do
    with {:ok, session_id} <-
           ExGames.Room.Server.reconnect(room_id, params["session_id"], token) do
      json(conn, %{
        "room_id" => room_id,
        "session_id" => session_id,
        "reconnection_token" => token
      })
    end
  end

  def reconnect(_conn, _params) do
    {:error, "reconnection_token required"}
  end

  defp auth_data(conn), do: %{"user_id" => conn.assigns.current_user.id}
  defp options(conn), do: conn.params["options"] || %{}
end
