defmodule ArenaExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :arena_example,
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
      mod: {ArenaExample.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_games, in_umbrella: true},
      {:ex_games_account, in_umbrella: true},
      {:ex_games_web, in_umbrella: true},
      # WS-клиент для интеграционных тестов полного цикла.
      # {:websock_client, "~> 0.2", only: :test} нет такого
    ]
  end
end
