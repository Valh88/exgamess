defmodule ExGames.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_games,
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
      mod: {ExGames.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Distributed-ready pub/sub: события листингов лобби, presence, чат.
      {:phoenix_pubsub, "~> 2.1"},
      # Только ради Phoenix.Tracker (движок presence); веб-слой не используется.
      {:phoenix, "~> 1.8"},
      # Бинарная сериализация кадров [opcode u8][msgpack].
      {:msgpax, "~> 2.3"},
      # Телеметрия жизненного цикла комнат/матчмейкера.
      {:telemetry, "~> 1.2"},
      {:jason, "~> 1.4"},
      {:lua, "~> 1.0.2"}
    ]
  end
end
