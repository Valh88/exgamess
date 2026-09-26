defmodule ExGames.Account.RankSource do
  @moduledoc """
  Реализация `ExGames.Matchmaking.RankSource` на рейтингах аккаунтов
  (Elo). Подключается конфигом в композиционном корне:

      config :ex_games, :rank_source, ExGames.Account.RankSource
  """

  @behaviour ExGames.Matchmaking.RankSource

  @impl true
  def rating(user_id, game), do: ExGames.Account.get_rating(user_id, game)
end
