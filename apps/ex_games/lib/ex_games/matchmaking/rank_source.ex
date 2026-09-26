defmodule ExGames.Matchmaking.RankSource do
  @moduledoc """
  Источник серверных рангов для стратегий подбора
  (см. `ExGames.Matchmaking.PairsByRank`).

  Ядро не знает о хранилище рейтингов: приложение-композиция выбирает
  реализацию конфигом (по умолчанию — отключено, ранги только клиентские):

      config :ex_games, :rank_source, MyApp.RankSource

  Колбэк `rating/2` возвращает `{:ok, rank}` или `:error` (ранга нет —
  стратегия возьмёт клиентский ранг из опций или базовый 1000).
  Реализация может бросать исключения — стратегия трактует их как `:error`.
  """

  @callback rating(user_id :: integer(), game :: String.t()) :: {:ok, integer()} | :error
end
