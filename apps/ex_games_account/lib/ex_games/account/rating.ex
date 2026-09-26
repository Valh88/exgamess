defmodule ExGames.Account.Rating do
  @moduledoc """
  Рейтинг игрока в конкретной игре (`game` — ключ, обычно имя типа
  матч-комнаты). Стартовый рейтинг — 1000. Используется стратегиями
  подбора через `ExGames.Matchmaking.RankSource`.
  """

  use Ecto.Schema

  schema "ex_games_ratings" do
    field :user_id, :integer
    field :game, :string, default: "default"
    field :rating, :integer, default: 1000
    field :wins, :integer, default: 0
    field :losses, :integer, default: 0
    field :draws, :integer, default: 0

    timestamps()
  end

  def changeset(rating, attrs) do
    rating
    |> Ecto.Changeset.cast(attrs, [:user_id, :game, :rating, :wins, :losses, :draws])
    |> Ecto.Changeset.validate_required([:user_id, :game, :rating])
    |> Ecto.Changeset.unique_constraint([:user_id, :game])
  end
end
