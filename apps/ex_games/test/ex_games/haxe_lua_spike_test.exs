defmodule ExGames.HaxeLuaSpikeTest do
  @moduledoc """
  Спайк Haxe→Lua (план, этап 5): общий Haxe-код (`sdk/lua-spike/source/`)
  компилируется `haxe -lua` в чанк `haxe_spike.lua` (коммитится в
  test/support/lua) и исполняется под песочницей VM пакета `lua`.

  Чек-лист плана: метатаблицы/прототипы, `_hx_bit` (нативные 5.3-операторы
  через шим bit32), String-операции (собственный движок паттернов VM),
  отсутствие зависимостей от os/io/coroutine/GC.

  Прелюдия Haxe ожидает полную Lua-среду (`require("lua-utf8")`,
  `pcall(require, 'bit32')`, `package.loaded.luv`) — песочница даёт только
  вычислительный stdlib. Спайк устанавливает **шимы**: utf8 — Elixir-функции
  (точный юникод), bit32 — Lua-таблица на нативных 5.3-операторах,
  package/require — управляемые заглушки.

  Вердикт: если все SPIKE-проверки проходят — go (флоу «один Haxe-исходник →
  hl/js клиенту + lua серверу» работает при наличии слоя шимов ~60 строк).
  """

  use ExUnit.Case, async: false

  import Lua

  @spike Path.expand("../support/lua/haxe_spike.lua", __DIR__)

  # -------------------------------------------------------------------------
  # Шимы (кандидат в ExGames.GameLogic.Adapters.Lua при go-вердикте)
  # -------------------------------------------------------------------------

  defp booted_lua do
    # продакшн-шимы (тот же код исполняет адаптер при haxe: true)
    ExGames.GameLogic.Adapters.Lua.Shims.install(Lua.new())
  end

  # -------------------------------------------------------------------------
  # Загрузка чанка Haxe под песочницей
  # -------------------------------------------------------------------------

  test "чанк Haxe загружается и самопроверки проходят" do
    assert File.exists?(@spike), "нет чанка; сгенерируйте: cd sdk/lua-spike && haxe build.hxml"

    lua = booted_lua()

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Lua.load_file!(lua, @spike)
      end)

    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "SPIKE"))

    assert length(lines) > 0, "SPIKE-вывода нет; вывод: #{inspect(output)}"

    failures =
      Enum.filter(lines, fn line ->
        String.contains?(line, "FAIL") or String.contains?(line, "FAIL")
      end)

    assert failures == [], "упавшие проверки: #{inspect(failures)}"

    assert Enum.any?(lines, &String.contains?(&1, "SPIKE failed=0")),
           "итог не failed=0: #{inspect(lines)}"
  end

  test "шимы изолированы: require посторонних модулей блокирован" do
    lua = booted_lua()

    {[false, message], _lua} =
      Lua.eval!(lua, ~LUA"return pcall(function() return require('io') end)")

    assert message =~ "require blocked"
  end
end
