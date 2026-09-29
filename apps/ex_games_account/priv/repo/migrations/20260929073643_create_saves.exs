defmodule ExGames.Account.Repo.Migrations.CreateSaves do
  use Ecto.Migration

  def change do
    # Облачные сохранения игроков. Payload — непрозрачный документ игры
    # (JSON): форму знает только игра, сервер ищет по "координатам"
    # (user_id + key). См. doc/DATABASE.md.
    create table(:ex_games_saves) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :key, :text, null: false
      add :payload, :map, null: false

      timestamps()
    end

    create unique_index(:ex_games_saves, [:user_id, :key])
  end
end
