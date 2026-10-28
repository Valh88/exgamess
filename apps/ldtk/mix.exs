defmodule Ldtk.MixProject do
  @moduledoc """
  Библиотека парсинга LDtk-проектов (https://ldtk.io — json) для игр
  зонтика exgamess. Без проектного кода: покрывает ровно то, что
  понадобилось (уровни, слои IntGrid, внешние уровни .ldtkl),
  расширяется по мере надобности.
  """

  use Mix.Project

  def project do
    [
      app: :ldtk,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end
end
