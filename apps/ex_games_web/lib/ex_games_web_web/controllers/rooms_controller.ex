defmodule ExGamesWebWeb.RoomsController do
  @moduledoc "REST: листинг комнат (для лобби)."

  use ExGamesWebWeb, :controller

  def index(conn, %{"room_name" => name}) do
    case ExGames.Matchmaker.query(name) do
      {:ok, listings} -> json(conn, %{"rooms" => listings})
      {:error, reason} -> json(conn, %{error: %{message: inspect(reason)}})
    end
  end

  def index(conn, _params) do
    json(conn, %{"rooms" => ExGames.Matchmaker.all_listings()})
  end
end
