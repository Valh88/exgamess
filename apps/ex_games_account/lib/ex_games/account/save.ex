defmodule ExGames.Account.Save do
  @moduledoc """
  Облачное сохранение игрока: слот `key` (например `"world1"`, `"profile"`)
  с непрозрачным документом `payload`.

  Форму payload знает только игра — сервер хранит его как есть (JSON-текст
  в БД) и ищет по «координатам» `user_id + key`; новые поля документа не
  требуют миграций. См. doc/DATABASE.md.
  """

  use Ecto.Schema

  schema "ex_games_saves" do
    field(:user_id, :integer)
    field(:key, :string)
    field(:payload, :map)

    timestamps()
  end

  def changeset(save, attrs) do
    save
    |> Ecto.Changeset.cast(attrs, [:user_id, :key, :payload])
    |> Ecto.Changeset.validate_required([:user_id, :key, :payload])
    |> Ecto.Changeset.validate_length(:key, min: 1, max: 128)
    |> Ecto.Changeset.unique_constraint([:user_id, :key])
  end
end
