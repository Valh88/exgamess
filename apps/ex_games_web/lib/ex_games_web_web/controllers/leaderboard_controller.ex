defmodule ExGamesWebWeb.LeaderboardController do
  @moduledoc """
  Лидерборд по игре — топ рейтингов (`Account.top_ratings/2`).

      GET /api/leaderboard/:game?limit=50

  Ответ:

      {"game": "arena", "entries": [
        {"position": 1, "user_id": 7, "username": "ann", "rating": 1120,
         "wins": 4, "losses": 1, "draws": 0}, ...
      ]}
  """

  use ExGamesWebWeb, :controller

  @max_limit 100

  def show(conn, %{"game" => game}) do
    limit =
      case Integer.parse(conn.params["limit"] || "") do
        {n, ""} when n > 0 -> min(n, @max_limit)
        _ -> 50
      end

    entries =
      Enum.map(ExGames.Account.top_ratings(game, limit), fn entry ->
        %{
          "position" => entry.position,
          "user_id" => entry.user_id,
          "username" => entry.username,
          "rating" => entry.rating,
          "wins" => entry.wins,
          "losses" => entry.losses,
          "draws" => entry.draws
        }
      end)

    json(conn, %{"game" => game, "entries" => entries})
  end
end
