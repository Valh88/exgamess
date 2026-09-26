defmodule Exgamess.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      apps: [:ex_games, :ex_games_account, :ex_games_web, :arena_example],
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Dependencies listed here are available only for this
  # umbrella project and cannot be accessed from the apps
  # inside apps/.
  defp deps do
    []
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": [
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "run apps/ex_games_account/priv/repo/seeds.exs"
      ],
      "ecto.reset": ["ecto.drop --quiet", "ecto.setup"],
      # drop перед тестами не нужен: изоляция через SQL Sandbox, а
      # create+migrate делают базу готовой; полный сброс — mix ecto.reset.
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
