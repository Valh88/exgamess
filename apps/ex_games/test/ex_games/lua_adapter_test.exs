defmodule ExGames.LuaAdapterTest do
  use ExUnit.Case, async: false

  alias ExGames.GameLogic.Adapters.Lua, as: LuaAdapter
  alias ExGames.GameLogic.Server, as: LogicServer

  @counter Path.expand("../support/lua/counter.lua", __DIR__)

  defp start_logic!(opts \\ []) do
    id = "lua_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        ExGames.LogicSupervisor,
        {LogicServer,
         Keyword.merge(
           [
             id: id,
             adapter: LuaAdapter,
             script: @counter,
             args: ["тест"]
           ],
           opts
         )}
      )

    id
  end

  # -------------------------------------------------------------------------
  # validate_doc/1 (чистая функция — без VM)
  # -------------------------------------------------------------------------

  describe "validate_doc/1" do
    test "скаляры проходят" do
      assert {:ok, nil} = LuaAdapter.validate_doc(nil)
      assert {:ok, true} = LuaAdapter.validate_doc(true)
      assert {:ok, 5} = LuaAdapter.validate_doc(5)
      assert {:ok, 0.5} = LuaAdapter.validate_doc(0.5)
      assert {:ok, "Привет"} = LuaAdapter.validate_doc("Привет")
    end

    test "таблица с целыми ключами — список по возрастанию" do
      assert {:ok, [1, 2, 3]} = LuaAdapter.validate_doc([{1, 1}, {2, 2}, {3, 3}])
      # дыры схлопываются
      assert {:ok, ["a", "b", "d"]} =
               LuaAdapter.validate_doc([{1, "a"}, {2, "b"}, {4, "d"}])
    end

    test "пустая таблица — пустой map" do
      assert {:ok, %{}} = LuaAdapter.validate_doc([])
    end

    test "map — строковые ключи, вложенность" do
      {:ok, doc} = LuaAdapter.validate_doc([{"a", 1}, {"b", [{"x", "y"}]}])
      assert doc == %{"a" => 1, "b" => %{"x" => "y"}}
    end

    test "отказ: tref / userdata / функция / нечисловое" do
      assert {:error, "$: table reference (cyclic?)"} =
               LuaAdapter.validate_doc({:tref, 1})

      assert {:error, "$: userdata"} = LuaAdapter.validate_doc({:userdata, :x})

      assert {:error, "$.bad: function"} =
               LuaAdapter.validate_doc([{"bad", {:lua_closure, nil, nil}}])
    end

    test "отказ: функция в документе (через скрипт с циклом)" do
      id = start_logic!()

      assert {:error, {:lua, msg}} = LogicServer.call(id, "cyclic", [])
      assert msg =~ "table reference"
      LogicServer.stop(id)
    end
  end

  # -------------------------------------------------------------------------
  # Через GameLogic.Server (как боевой путь)
  # -------------------------------------------------------------------------

  describe "adapter via GameLogic.Server" do
    test "init: state из скрипта с аргументами (строковые ключи)" do
      id = start_logic!()
      assert {:ok, %{"count" => 0, "ticks" => 0, "label" => "тест"}} = LogicServer.state(id)
      LogicServer.stop(id)
    end

    test "call: {result, state} и {nil, state}" do
      id = start_logic!()

      assert {:ok, %{"op" => "add", "total" => 7}} = LogicServer.call(id, "add", [7])
      assert {:ok, %{"count" => 7}} = LogicServer.state(id)

      assert {:ok, nil} = LogicServer.call(id, "get", [])
      assert {:ok, %{"count" => 7}} = LogicServer.state(id)
      LogicServer.stop(id)
    end

    test "call: вложенные документы roundtrip" do
      id = start_logic!()

      {:ok, doc} = LogicServer.call(id, "nested", ["x"])
      assert doc["label"] == "x"
      assert doc["inner"] == %{"a" => 1, "list" => [10, 20, 30]}
      assert doc["flags"] == [true, false]
      # state при этом не изменился
      assert {:ok, %{"count" => 0, "ticks" => 0, "label" => "тест"}} = LogicServer.state(id)

      LogicServer.stop(id)
    end

    test "tick: {result, state} через Server.tick/1 (факультативный результат)" do
      id = start_logic!()

      # dt первого тика зависит от времени с init (может быть 0) —
      # проверяем форму: эффекты согласованы со state
      assert {:ok, effects, state} = LogicServer.tick(id)
      assert is_map(state) and is_integer(state["ticks"])
      assert effects == ["broadcast", "ticked", %{"ticks" => state["ticks"]}]

      LogicServer.stop(id)
    end

    test "ошибка скрипта — {:error, {:lua, msg}} со строкой ошибки" do
      id = start_logic!()

      assert {:error, {:lua, msg}} = LogicServer.call(id, "fail", [])
      assert msg =~ "boom"
      # откат: состояние прежнее, VM жива
      assert {:ok, nil} = LogicServer.call(id, "get", [])
      assert {:ok, %{"count" => 0}} = LogicServer.state(id)
      LogicServer.stop(id)
    end

    test "песочница: os.execute недоступен" do
      id = start_logic!()

      assert {:error, {:lua, msg}} = LogicServer.call(id, "sandbox", [])
      assert is_binary(msg)
      LogicServer.stop(id)
    end

    test "бюджет инструкций: while true — ошибка, не зависание" do
      id = start_logic!(max_instructions: 10_000)

      assert {:error, {:lua, msg}} = LogicServer.call(id, "loop", [])
      assert msg =~ "instruction budget exceeded"
      LogicServer.stop(id)
    end

    test "циклическая таблица — внятная ошибка validate_doc" do
      id = start_logic!()

      assert {:error, {:lua, msg}} = LogicServer.call(id, "cyclic", [])
      assert msg =~ "table reference"
      LogicServer.stop(id)
    end

    test "кириллица строкой на круге" do
      id = start_logic!()

      assert {:ok, %{"text" => "Привет, мир!"}} = LogicServer.call(id, "cyrillic", [])
      LogicServer.stop(id)
    end

    test "integer/float различаются" do
      id = start_logic!()

      assert {:ok, %{"i" => 2, "f" => 0.5}} = LogicServer.call(id, "numbers", [])
      LogicServer.stop(id)
    end
  end

  describe "start_link" do
    test "ошибка компиляции скрипта" do
      broken = Path.expand("../support/lua/broken.lua", __DIR__)
      assert {:error, {:lua, msg}} = LuaAdapter.start_link(script: broken)
      assert is_binary(msg)
    end

    test "init вернул функцию — отказ validate_doc" do
      bad = Path.expand("../support/lua/badinit.lua", __DIR__)
      assert {:error, {:lua, msg}} = LuaAdapter.start_link(script: bad)
      assert msg =~ "M.init: $: function"
    end

    test "нет таблицы M" do
      nom = Path.expand("../support/lua/nom.lua", __DIR__)
      assert {:error, {:lua, msg}} = LuaAdapter.start_link(script: nom)
      assert is_binary(msg)
    end
  end

  # -------------------------------------------------------------------------
  # Haxe-чанк (шимы рантайма Haxe, опция haxe: true)
  # -------------------------------------------------------------------------

  @mlogic Path.expand("../support/lua/haxe_mlogic.lua", __DIR__)

  describe "Haxe runtime" do
    test "чанк Haxe с контрактом M работает при haxe: true" do
      id = start_logic!(script: @mlogic, args: [], haxe: true)

      # M.init из Haxe
      assert {:ok, %{"count" => 0, "joins" => %{}}} = LogicServer.state(id)

      # M.call → {эффекты, state}: список эффектов (форма моста) + state
      assert {:ok, [["broadcast", "added", %{"total" => 3}]]} =
               LogicServer.call(id, "message", ["add", "s1", %{"n" => 3}])

      assert {:ok, %{"count" => 3, "joins" => %{}}} = LogicServer.state(id)

      # join-ветка
      assert {:ok, [["broadcast", "haxe_joined", %{"sid" => "s9"}]]} =
               LogicServer.call(id, "join", ["s9", %{"token" => "t"}])

      assert {:ok, %{"joins" => %{"s9" => true}}} = LogicServer.state(id)

      LogicServer.stop(id)
    end

    test "без шимов Haxe-чанк не загружается (прелюдия требует require)" do
      assert {:error, {:lua, msg}} = LuaAdapter.start_link(script: @mlogic)
      assert is_binary(msg)
    end
  end
end
