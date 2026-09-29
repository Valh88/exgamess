defmodule ExGamesWebWeb.LeaderboardAPITest do
  # async: false — SQLite не держит параллельные записи нескольких модулей.
  use ExGamesWebWeb.ConnCase, async: false

  alias ExGames.Account

  # GET /api/leaderboard/:game — топ рейтингов (позиции, имена, счётчики).

  defp two_players_with_match(%{conn: conn}) do
    u1 = register_user!(conn)
    u2 = register_user!(conn)

    {:ok, _} =
      Account.record_match("arena", %{
        u1["user"]["id"] => :win,
        u2["user"]["id"] => :loss
      })

    %{u1: u1, u2: u2}
  end

  test "топ отсортирован по рейтингу, позиции с 1", %{conn: conn} do
    %{u1: u1, u2: _u2} = two_players_with_match(%{conn: conn})

    conn =
      auth_conn(build_conn(), u1["token"])
      |> get("/api/leaderboard/arena")

    %{"game" => "arena", "entries" => entries} = json_response(conn, 200)

    assert [%{"position" => 1}, %{"position" => 2}] = entries
    assert hd(entries)["user_id"] == u1["user"]["id"]
    assert hd(entries)["rating"] == 1016
    assert is_binary(hd(entries)["username"])

    assert Enum.map(entries, & &1["rating"]) ==
             Enum.sort(Enum.map(entries, & &1["rating"]), :desc)
  end

  test "limit ограничивает выдачу", %{conn: conn} do
    %{u1: u1} = two_players_with_match(%{conn: conn})

    conn =
      auth_conn(build_conn(), u1["token"])
      |> get("/api/leaderboard/arena?limit=1")

    assert %{"entries" => [%{"position" => 1}]} = json_response(conn, 200)
  end

  test "игра без матчей — пустой список", %{conn: conn} do
    %{u1: u1} = two_players_with_match(%{conn: conn})

    conn =
      auth_conn(build_conn(), u1["token"])
      |> get("/api/leaderboard/no-such-game")

    assert %{"entries" => []} = json_response(conn, 200)
  end

  test "без токена — 401", %{conn: conn} do
    conn = get(conn, "/api/leaderboard/arena")
    assert json_response(conn, 401)
  end
end
