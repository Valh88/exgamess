defmodule ExGames.Account.Repo.Migrations.CreateUsersRoles do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string, null: false
      add :password_hash, :string, null: false
      add :banned_at, :utc_datetime
      add :ban_reason, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:username])

    create table(:roles) do
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:roles, [:name])

    create table(:users_roles, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role_id, references(:roles, on_delete: :delete_all), null: false
    end

    create unique_index(:users_roles, [:user_id, :role_id])
  end
end
