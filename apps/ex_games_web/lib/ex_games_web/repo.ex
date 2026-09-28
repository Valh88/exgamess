defmodule ExGamesWeb.Repo do
  use Ecto.Repo,
    otp_app: :ex_games_web,
    adapter: Ecto.Adapters.SQLite3
end
