defmodule Mix.Tasks.ExGames.Scripts do
  @shortdoc "Собирает server_scripts/** (Haxe → Lua-чанки) и освежает схемы"

  @moduledoc """
  Серверная обёртка над конвенцией `server_scripts/` (то же, что
  `gamessa run`, плюс автоматическая регенерация JSON-схем для
  типизированного клиента):

      mix ex_games.scripts                  # собрать все скрипты + схемы
      mix ex_games.scripts --schemas-only   # только схемы из существующих чанков

  Конвенция: `<app>/server_scripts/**/*.hx` — каждый `.hx` (рекурсивно),
  наследующий `gamessa.script.ServerLogic`, → чанк
  `<app>/priv/lua/<относительный путь>/<Class>.lua` (зеркало дерева) +
  `<Class>.lua.schema.json`.

  Компилятор — haxe (в PATH). SDK подключается как `-lib gamessa`
  (рекомендуется: `haxelib dev gamessa <путь к SDK>`; зависимости либы
  haxelib подтягивает сам); без haxelib — fallback `-cp` (findUp
  `<root>/sdk/gamessa/source` или env GAMESSA_SDK).
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    schemas_only? = "--schemas-only" in args
    lib_mode? = gamessa_lib?()

    for root <- roots() do
      scripts_dir = Path.join(root, "server_scripts")

      if File.dir?(scripts_dir) do
        walk!(
          %{root: root, lib_mode: lib_mode?, schemas_only: schemas_only?},
          scripts_dir,
          scripts_dir,
          ""
        )
      end
    end

    :ok
  end

  # -------------------------------------------------------------------------

  defp walk!(ctx, base, dir, rel) do
    for entry <- File.ls!(dir) |> Enum.sort() do
      path = Path.join(dir, entry)
      rel_path = if rel == "", do: entry, else: "#{rel}/#{entry}"

      cond do
        File.dir?(path) ->
          walk!(ctx, base, path, rel_path)

        Path.extname(entry) == ".hx" ->
          class = Path.rootname(entry)

          if String.contains?(File.read!(path), "ServerLogic") do
            out_rel = Path.join(Path.dirname(rel_path), class <> ".lua")
            out = Path.join([ctx.root, "priv", "lua", out_rel])

            unless ctx.schemas_only do
              build!(ctx, dir, class, out)
            end

            schema!(out)
          end

        true ->
          :skip
      end
    end

    :ok
  end

  defp build!(ctx, dir, class, out) do
    File.mkdir_p!(Path.dirname(out))

    haxe_args =
      cond do
        ctx.lib_mode ->
          ["-lib", "gamessa"]

        true ->
          case sdk_source(ctx.root) do
            nil -> []
            source -> ["-cp", source]
          end
      end
      |> Kernel.++(["-cp", dir, "-main", class, "-D", "lua-ver=5.3", "-lua", out])

    case System.cmd("haxe", haxe_args, into: IO.stream(:stdio, :line)) do
      {_, 0} -> Mix.shell().info("built #{class} -> #{out}")
      {_, code} -> Mix.raise("haxe failed (#{code}) for #{class}")
    end
  end

  defp schema!(out) do
    case ExGames.Room.Logics.Lua.extract_schema(out) do
      {:ok, schema} ->
        json = Path.rootname(out) <> ".schema.json"
        File.write!(json, Jason.encode!(schema, pretty: true) <> "\n")
        Mix.shell().info("schema #{json}")

      :error ->
        Mix.shell().error(
          "schema: не удалось извлечь M.schema из #{out} (не ServerLogic-скрипт?)"
        )
    end
  end

  defp gamessa_lib? do
    {_, code} = System.cmd("haxelib", ["path", "gamessa"], stderr_to_stdout: true)
    code == 0
  end

  defp roots do
    cond do
      File.dir?("server_scripts") ->
        ["."]

      File.dir?("apps") ->
        for app <- File.ls!("apps"),
            app != "_build",
            File.dir?(Path.join(["apps", app, "server_scripts"])) do
          Path.join("apps", app)
        end

      true ->
        Mix.raise(
          "server_scripts/ не найден (запускайте из каталога приложения или из корня зонда)"
        )
    end
  end

  defp sdk_source(root) do
    env = System.get_env("GAMESSA_SDK")
    marker = "gamessa/script/ServerLogic.hx"

    candidates =
      [env, Path.join([root, "..", "..", "sdk", "gamessa", "source"])]
      |> Enum.reject(&is_nil/1)

    Enum.find(candidates, fn source -> File.exists?(Path.join(source, marker)) end)
  end
end
