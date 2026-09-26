defmodule ExGames.Account.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_games_account,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExGames.Account.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Контракт RankSource (серверные ранги для подбора) + umbrella-ядро.
      {:ex_games, in_umbrella: true},
      # Ecto + адаптер SQLite (переход на Postgres = смена адаптера и конфига).
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, ">= 0.18.0"},
      # Хэширование паролей: чистый Elixir, не требует MSVC на Windows.
      {:pbkdf2_elixir, "~> 1.2"},
      # Подпись auth-токенов (HMAC) — тот же механизм, что внутри Phoenix.Token.
      {:plug_crypto, "~> 2.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
