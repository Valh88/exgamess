defmodule Mix.Tasks.ExGames.LuaSchema do
  @shortdoc "Извлекает M.schema Lua-скрипта в JSON-артефакт для Haxe-макроса SDK"

  @moduledoc """
  Headless-прогон Lua-скрипта в одноразовой VM: читает `M.schema`
  (таблица или результат вызова `M.schema()`) и пишет JSON-артефакт.
  Артефакт коммитится и читается компилятором Haxe-макросом
  `gamessa.script.Schema` — единый источник правды о форме состояния
  и типах сообщений для типизированного `Room<S>` на клиенте.

      mix ex_games.lua_schema priv/lua/arena.lua
      mix ex_games.lua_schema priv/lua/arena.lua -o priv/lua/arena.schema.json

  По умолчанию артефакт пишется рядом со скриптом:
  `<script>.schema.json`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, argv, _invalid} = OptionParser.parse(args, strict: [output: :string], aliases: [o: :output])

    script =
      case argv do
        [script] -> script
        _ -> Mix.raise("usage: mix ex_games.lua_schema <script.lua> [-o <out.json>]")
      end

    case ExGames.Room.Logics.Lua.extract_schema(script) do
      {:ok, schema} ->
        out = opts[:output] || Path.rootname(script) <> ".schema.json"
        File.write!(out, Jason.encode!(schema, pretty: true) <> "\n")
        Mix.shell().info("schema extracted: #{script} -> #{out}")

      :error ->
        Mix.raise("не удалось извлечь M.schema из #{script} (нет схемы или ошибка скрипта)")
    end
  end
end
