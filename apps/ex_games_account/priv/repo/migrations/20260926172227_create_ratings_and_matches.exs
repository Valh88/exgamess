defmodule ExGames.Account.Repo.Migrations.CreateRatingsAndMatches do
  use Ecto.Migration

  def change do
    # Схема ядерных рейтингов подбора (ExGames.Matchmaking.Ratings):
    # таблицы живут в общей БД аккаунтов, FK — на игроков.
    create table(:ex_games_ratings) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :game, :text, null: false, default: "default"
      add :rating, :integer, null: false, default: 1000
      add :wins, :integer, null: false, default: 0
      add :losses, :integer, null: false, default: 0
      add :draws, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:ex_games_ratings, [:user_id, :game])

    create table(:ex_games_matches) do
      add :game, :text, null: false
      # %{"user_id" => "win" | "loss" | "draw"}
      add :results, :map, null: false

      timestamps()
    end
  end
end
