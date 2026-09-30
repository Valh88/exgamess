defmodule ExGames.GameLogic.Adapters.Lua.Shims do
  @moduledoc """
  Шимы для Haxe→Lua чанков (спайк Haxe→Lua — вердикт go): прелюдия Haxe
  безусловно зовёт `require("lua-utf8")`, через `pcall` — `require('bit32'|'bit')`
  и читает `package.loaded` (guard цикла событий luv). Песочница VM блокирует
  `require` и удаляет `package` — без шимов чанк падает на первой строке.

  Шимы дают чанку ровно эти зависимости, не открывая песочницу:

    * `utf8` — Elixir-функции (`String.*`), полный юникод;
    * `bit32`/`bit` — Lua-таблица на нативных 5.3-операторах (`&`, `|`, `~`, `<<`, `>>`);
    * `package`/`require` — управляемые заглушки: два модуля Haxe выдаются,
      всё прочее остаётся ошибкой (`require blocked in sandbox`).

  Включается опцией адаптера `haxe: true` (мост: `use ExGames.Room.Logics.Lua,
  script: ..., haxe: true` или опция комнаты `lua_haxe: true`). Для чистых
  Lua-скриптов безвредны, потому опциональны.
  """

  import Lua

  @doc "Ставит шимы в свежую VM; вызвать до `Lua.load_file!/2`."
  @spec install(Lua.t()) :: Lua.t()
  def install(lua) do
    lua
    |> utf8_shim()
    |> runtime_shim()
  end

  # Прелюдия Haxe юзает subset lua-utf8: len/lower/upper/char/byte/sub/find.
  defp utf8_shim(lua) do
    lua
    |> Lua.set!(["__hx_utf8", "len"], fn [s] -> String.length(s) end)
    |> Lua.set!(["__hx_utf8", "lower"], fn [s] -> String.downcase(s) end)
    |> Lua.set!(["__hx_utf8", "upper"], fn [s] -> String.upcase(s) end)
    |> Lua.set!(["__hx_utf8", "char"], fn codes ->
      codes |> Enum.map(&<<&1::utf8>>) |> IO.iodata_to_binary()
    end)
    |> Lua.set!(["__hx_utf8", "byte"], fn [s, i] -> :binary.at(s, i - 1) end)
    |> Lua.set!(["__hx_utf8", "sub"], fn [s, i, j] -> utf8_sub(s, i, j) end)
    |> Lua.set!(["__hx_utf8", "find"], fn [s, needle, init, _plain] ->
      utf8_find(s, needle, init)
    end)
  end

  defp runtime_shim(lua) do
    {_results, lua} =
      Lua.eval!(lua, ~LUA"""
      package = { loaded = {} }

      local bitlib = {
        band = function(a, b) return a & b end,
        bor = function(a, b) return a | b end,
        bxor = function(a, b) return a ~ b end,
        bnot = function(a) return ~a end,
        lshift = function(a, b) return a << b end,
        rshift = function(a, b) return a >> b end,
        arshift = function(a, b) return a >> b end,
      }
      bit32 = bitlib
      bit = bitlib

      function require(name)
        if name == "lua-utf8" then return __hx_utf8 end
        if name == "bit32" or name == "bit" then return bit32 end
        error("require blocked in sandbox: " .. tostring(name))
      end

      -- Haxe-значения → plain-таблицы (контракт документов моста):
      -- массивы Haxe 0-based (поле length) → 1-based plain, объекты _hx_o
      -- (маркер __fields__) → без служебных ключей. Рекурсивно.
      function __hx_toplain(v)
        if type(v) ~= "table" then return v end
        local len = rawget(v, "length")
        local out = {}
        if type(len) == "number" then
          for i = 0, len - 1 do out[i + 1] = __hx_toplain(v[i]) end
        else
          for k, val in pairs(v) do
            if k ~= "__fields__" and k ~= "length" then out[k] = __hx_toplain(val) end
          end
        end
        return out
      end
      """)

    lua
  end

  # 1-based, инклюзивные границы, отрицательные — от конца (семантика lua-utf8)
  defp utf8_sub(s, i, j) do
    len = String.length(s)
    from = if i < 0, do: len + i + 1, else: i
    to = if j < 0, do: len + j + 1, else: j
    from = max(from, 1)
    to = min(to, len)

    if from > to do
      ""
    else
      String.slice(s, (from - 1)..(to - 1))
    end
  end

  # lua-utf8 find (plain): {start, end} в символах или nil
  defp utf8_find(s, needle, init) do
    prefix_len = max(init - 1, 0)
    tail = String.slice(s, prefix_len..-1//1)

    case :binary.match(tail, needle) do
      {byte_pos, _len} ->
        char_pos = String.length(String.slice(tail, 0..(byte_pos - 1)//1)) + prefix_len + 1
        {:ok, [char_pos, char_pos + String.length(needle) - 1]}

      :nomatch ->
        nil
    end
  end
end
