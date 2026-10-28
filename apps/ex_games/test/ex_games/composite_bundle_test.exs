defmodule ExGames.CompositeBundleTest do
  @moduledoc """
  Композитный бандл (`gamessa.script.Composite`) настоящим чанком через
  настоящий Lua-адаптер — на примере арены (`arena_example/server_scripts/
  composite/Bundle.hx` → `priv/lua/composite/Bundle.lua`).

  Регресс-покрытие диспетчеризации wire-вызовов в композите: Join/Message/
  Request проходят с аргументами (на Lua ключи аргументов числовые —
  ScriptWire.get; расхождение wireArgs/get ломало join/message тихо).
  """

  use ExUnit.Case, async: false

  alias ExGames.GameLogic.Adapters.Lua, as: LuaAdapter
  alias ExGames.GameLogic.Server, as: LogicServer

  @bundle Path.expand("../../../arena_example/priv/lua/composite/Bundle.lua", __DIR__)

  defp start_bundle!(opts \\ []) do
    id = "composite_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        ExGames.LogicSupervisor,
        {LogicServer,
         Keyword.merge([id: id, adapter: LuaAdapter, script: @bundle, haxe: true], opts)}
      )

    id
  end

  test "композит: init/join/message/request маршрутизируются по модулям" do
    id = start_bundle!()

    # init: обе ветки в общем документе
    {:ok, state0} = LogicServer.state(id)
    assert %{"score" => %{"points" => 0}, "ticker" => %{"ticks" => 0}} = state0

    # join: sid доходит до модуля-владельца (и в catch-all)
    assert {:ok, nil} = LogicServer.call(id, "join", ["s1", %{}])
    {:ok, s1} = LogicServer.state(id)
    assert s1["score"]["joins"]["s1"] == true, "join: #{inspect(s1["score"])}"

    # message владельцу: очки, broadcast-эффект
    assert {:ok, [["broadcast", "score", %{"sid" => "s1", "points" => 5}]]} =
             LogicServer.call(id, "score", ["score", "s1", %{"add" => 5}])

    # message без владельца -> catch-all Ticker
    assert {:ok, nil} = LogicServer.call(id, "ping", ["ping", "s1", %{}])
    {:ok, s2} = LogicServer.state(id)
    assert s2["score"]["points"] == 5
    assert s2["ticker"]["unknown"] == 1, "catch-all: #{inspect(s2["ticker"])}"

    # request владельцу: значение-ответ
    assert {:ok, 5} = LogicServer.call(id, "request", ["score_get", "s1", %{}])

    # тики идут обоим модулям
    {:ok, _, s3} = LogicServer.tick(id)
    assert s3["ticker"]["ticks"] >= 1 and s3["score"]["ticked"] >= 1
  end
end
