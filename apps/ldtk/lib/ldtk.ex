defmodule LDtk do
  @moduledoc """
  Парсер LDtk-проектов (json) — библиотека зонтика, переиспользуемая
  играми. Минимальный фасад над форматом: корень проекта, уровни
  (внешние `.ldtkl` подтягиваются по `externalRelPath`), слои —
  с разбором IntGrid (`intGridCsv`/старый `intGrid`).

  Данные — плоские map'ы (нормализованные atom-ключи), удобно скармливать
  Lua-мосту и сравнивать в тестах. Расширяется по мере надобности: слои
  Tiles/Entities пока отдаются сырыми (`type`, размеры), контент не
  нормализуется.
  """

  alias __MODULE__

  @typedoc "Нормализованный слой; int_grid — только для слоёв IntGrid."
  @type layer :: %{
          required(:type) => String.t(),
          required(:c_wid) => non_neg_integer(),
          required(:c_hei) => non_neg_integer(),
          required(:grid_size) => non_neg_integer(),
          required(:int_grid) => %{non_neg_integer() => pos_integer()} | nil
        }

  @typedoc "Нормализованный уровень; source — файл, из которого прочитан."
  @type level :: %{
          required(:identifier) => String.t(),
          required(:world_x) => integer(),
          required(:world_y) => integer(),
          required(:px_wid) => integer(),
          required(:px_hei) => integer(),
          required(:layers) => %{String.t() => layer()},
          required(:source) => String.t()
        }

  @typedoc "Проект: уровни по identifier."
  @type project :: %{
          required(:dir) => String.t(),
          required(:json_version) => String.t() | nil,
          required(:levels) => %{String.t() => level()}
        }

  @doc """
  Прочитать проект по пути `.ldtk`. Внешние уровни (`externalLevels`)
  подтягиваются из соседних файлов; каждый уровень помечен `source` —
  путь файла, из которого он прочитан (для `@external_resource`).
  """
  @spec read!(Path.t()) :: project()
  def read!(path) do
    root_path = Path.expand(path)
    dir = Path.dirname(root_path)
    root = root_path |> File.read!() |> Jason.decode!()
    external? = Map.get(root, "externalLevels", false)

    levels =
      for lvl <- root["levels"], into: %{} do
        {source, layer_instances} =
          if external? do
            rel = Map.fetch!(lvl, "externalRelPath")
            ext = Path.join(dir, rel)
            {ext, ext |> File.read!() |> Jason.decode!() |> Map.get("layerInstances", [])}
          else
            {root_path, Map.get(lvl, "layerInstances", [])}
          end

        {lvl["identifier"], level(lvl, source, layer_instances)}
      end

    %{
      dir: dir,
      json_version: root["jsonVersion"],
      levels: levels
    }
  end

  @doc """
  Все файлы проекта (корень + внешние уровни) — для `@external_resource`
  в compile-time читателях: правка карты в редакторе перекомпилирует
  модуль.
  """
  @spec source_paths!(Path.t()) :: [String.t()]
  def source_paths!(path) do
    root_path = Path.expand(path)
    root = root_path |> File.read!() |> Jason.decode!()

    externals =
      if Map.get(root, "externalLevels", false) do
        dir = Path.dirname(root_path)

        for lvl <- root["levels"],
            rel = lvl["externalRelPath"],
            do: Path.join(dir, rel)
      else
        []
      end

    [root_path | externals] |> Enum.uniq()
  end

  # -- внутренности -----------------------------------------------------------

  defp level(lvl, source, layer_instances) do
    layers =
      for li <- layer_instances, into: %{} do
        {li["__identifier"],
         %{
           type: li["__type"],
           c_wid: li["__cWid"],
           c_hei: li["__cHei"],
           grid_size: li["__gridSize"],
           int_grid: int_grid(li)
         }}
      end

    %{
      identifier: lvl["identifier"],
      world_x: lvl["worldX"],
      world_y: lvl["worldY"],
      px_wid: lvl["pxWid"],
      px_hei: lvl["pxHei"],
      layers: layers,
      source: source
    }
  end

  # IntGrid -> %{coordId => value}, 0-значения опущены. coordId 0-based,
  # row-major (cx + cy * cWid) — та же раскладка, что в Haxe-клиенте.
  defp int_grid(%{"__type" => "IntGrid", "intGridCsv" => csv}) when is_list(csv) do
    csv
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {0, _i}, acc -> acc
      {v, i}, acc -> Map.put(acc, i, v)
    end)
  end

  defp int_grid(%{"__type" => "IntGrid", "intGrid" => cells}) when is_list(cells) do
    for %{"coordId" => id, "v" => v} <- cells, v != 0, into: %{}, do: {id, v}
  end

  defp int_grid(_layer), do: nil
end
