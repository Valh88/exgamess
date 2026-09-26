defmodule ExGames.Account.MatchResult do
  @moduledoc """
  Запись о сыгранном матче: игра + исходы участников
  (`%{"user_id" => "win" | "loss" | "draw"}`).
  """

  use Ecto.Schema

  schema "ex_games_matches" do
    field :game, :string
    field :results, :map

    timestamps()
  end

  def changeset(match, attrs) do
    match
    |> Ecto.Changeset.cast(attrs, [:game, :results])
    |> Ecto.Changeset.validate_required([:game, :results])
  end
end
