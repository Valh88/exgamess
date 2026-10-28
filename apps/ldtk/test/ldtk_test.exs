defmodule LDtkTest do
  @moduledoc """
  Парсер на мини-фикстурах: внутренние уровни (intGridCsv + старый
  intGrid), внешние уровни (.ldtkl), source_paths для external_resource.
  """

  use ExUnit.Case, async: true

  @root Path.expand("fixtures/mini.ldtk", __DIR__)
  @ext_root Path.expand("fixtures/mini_ext.ldtk", __DIR__)

  test "read!: внутренние уровни, IntGrid как map coordId->значение" do
    proj = LDtk.read!(@root)
    assert Map.has_key?(proj.levels, "Mini_W")
    assert Map.has_key?(proj.levels, "Mini_E")

    nw = proj.levels["Mini_W"]
    assert nw.world_x == 0 and nw.world_y == 0
    assert nw.px_wid == 64 and nw.px_hei == 64

    ig = nw.layers["Collisions"]
    assert ig.type == "IntGrid"
    assert ig.c_wid == 2 and ig.c_hei == 2
    assert ig.grid_size == 32
    # intGridCsv [1,0,0,0] -> coordId 0 = стена, нули опущены
    assert ig.int_grid == %{0 => 1}

    # старый формат intGrid: coordId 3 = вода (значение 2)
    assert proj.levels["Mini_E"].layers["Collisions"].int_grid == %{3 => 2}

    # source — сам корень (уровни внутренние)
    assert nw.source == Path.expand(@root)
  end

  test "read!: внешние уровни подтягиваются из .ldtkl" do
    proj = LDtk.read!(@ext_root)
    lvl = proj.levels["Ext_N"]
    assert lvl.world_x == 0
    assert lvl.layers["Collisions"].int_grid == %{0 => 1}
    # source — внешний файл, не корень
    assert lvl.source == Path.expand("fixtures/ext/Ext_N.ldtkl", __DIR__)
  end

  test "source_paths!: корень + все внешние файлы, без дублей" do
    assert LDtk.source_paths!(@root) == [Path.expand(@root)]

    paths = LDtk.source_paths!(@ext_root)
    assert paths == [Path.expand(@ext_root), Path.expand("fixtures/ext/Ext_N.ldtkl", __DIR__)]
  end
end
