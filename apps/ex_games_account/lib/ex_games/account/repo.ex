defmodule ExGames.Account.Repo do
  @moduledoc """
  Репозиторий аккаунтов. Адаптер SQLite; для перехода на PostgreSQL достаточно
  заменить `adapter` здесь и конфиг `:database` (DSN) — код остаётся Ecto-овым.
  """
  use Ecto.Repo,
    otp_app: :ex_games_account,
    adapter: Ecto.Adapters.SQLite3
end
