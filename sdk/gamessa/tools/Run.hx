/**
	gamessa run — сборка серверных Haxe-скриптов в Lua-чанки.

	Конвенция (в проекте, использующем gamessa):

	  <root>/server_scripts/**​/Xxx.hx  — РЕКУРСИВНО: каждый .hx (на любой
	      глубине), наследующий gamessa.script.ServerLogic, компилируется в
	      СВОЙ чанк <root>/priv/lua/<относительный путь>/<Xxx>.lua
	      (зеркало дерева server_scripts; путь — для lua_script: моста).
	      .hx без ServerLogic и подкаталоги — общие исходники своего
	      каталога (попадают в чанки через -cp, отдельно не собираются).

	Запуск:
	  haxelib run gamessa run [roots...]     # через haxelib
	  hl bin/run.hl run [roots...]           # напрямую из каталога SDK
	  gamessa help

	roots (default: текущий каталог) — каталоги с server_scripts/.
	SDK подключается как -lib gamessa (нужен `haxelib dev gamessa <путь>`);
	если haxelib не знает либу — fallback: findUp (<root>/sdk/gamessa/source)
	или env GAMESSA_SDK (-cp). Зависимости самой либы haxelib подтягивает сам.
	Пересборка раннера: haxe tools/build_run.hxml (из каталога SDK).
**/
import sys.FileSystem;
import sys.io.File;

class Run {
	static function main() {
		final args = Sys.args().copy();

		// haxelib run gamessa ... : последний аргумент — каталог установки либы
		var libDir:Null<String> = null;
		if (args.length > 0 && FileSystem.exists(args[args.length - 1]) && FileSystem.isDirectory(args[args.length - 1])) {
			libDir = args[args.length - 1];
			args.pop();
		}

		final cmd = args.length > 0 ? args.shift() : "run";
		switch (cmd) {
			case "run":
				runAll(args.length > 0 ? args : ["."], libDir);
			case _:
				Sys.println("gamessa — серверные Haxe-скрипты для ExGames\n"
					+ "\n  gamessa run [roots...]   собрать server_scripts/** -> priv/lua/** (рекурсивно)"
					+ "\n  gamessa help             эта справка");
		}
	}

	static function runAll(roots:Array<String>, haxelibDir:Null<String>) {
		final libMode = haxeHasGamessa();
		final sourceCp = libMode ? null : findSource(haxelibDir);

		if (libMode)
			Sys.println("sdk: -lib gamessa (haxelib)");
		else if (sourceCp != null)
			Sys.println("sdk: -cp " + sourceCp + " (haxelib dev gamessa <путь> включит -lib)");
		else {
			Sys.println("WARN: gamessa не найден ни в haxelib, ни findUp, ни GAMESSA_SDK");
			Sys.println("      (haxelib dev gamessa <путь к sdk> — рекомендуемый способ)");
		}

		var built = 0;

		for (root in roots) {
			final scriptsDir = root + "/server_scripts";
			if (!FileSystem.exists(scriptsDir)) {
				Sys.println("skip (нет server_scripts/): " + root);
				continue;
			}

			built += walk(root, scriptsDir, "", libMode, sourceCp);
		}

		Sys.println('gamessa run: built=$built failed=$failures');
		if (failures > 0)
			Sys.exit(1);
	}

	static var failures:Int = 0;

	static function walk(root:String, dir:String, rel:String, libMode:Bool, sourceCp:Null<String>):Int {
		var built = 0;

		for (entry in FileSystem.readDirectory(dir)) {
			final path = dir + "/" + entry;
			final relPath = rel == "" ? entry : rel + "/" + entry;

			if (FileSystem.isDirectory(path)) {
				built += walk(root, path, relPath, libMode, sourceCp);
				continue;
			}

			if (!StringTools.endsWith(entry, ".hx"))
				continue;

			// каждый ServerLogic-наследник на любой глубине — отдельный чанк
			final cls = entry.substring(0, entry.length - 3);
			if (File.getContent(path).indexOf("ServerLogic") < 0)
				continue;

			final outDirParts = rel == "" ? [] : rel.split("/");
			final outDir = [root, "priv", "lua"].concat(outDirParts).join("/");
			if (!FileSystem.exists(outDir))
				FileSystem.createDirectory(outDir);

			final out = outDir + "/" + cls + ".lua";

			var haxeArgs:Array<String> = [];
			if (libMode) {
				haxeArgs = haxeArgs.concat(["-lib", "gamessa"]);
			} else if (sourceCp != null) {
				haxeArgs = haxeArgs.concat(["-cp", sourceCp]);
			}
			haxeArgs = haxeArgs.concat(["-cp", dir, "-main", cls, "-D", "lua-ver=5.3", "-lua", out]);

			Sys.println("build " + relPath + " -> " + out.substring(root.length + 1));
			if (Sys.command("haxe", haxeArgs) == 0)
				built++
			else
				failures++;
		}

		return built;
	}

	static function haxeHasGamessa():Bool {
		final p = try new sys.io.Process("haxelib", ["path", "gamessa"]) catch (_:Dynamic) return false;
		final out = p.stdout.readAll().toString();
		final code = p.exitCode();
		p.close();
		return code == 0 && out.indexOf("does not have") < 0;
	}

	/** Путь к каталогу source SDK: findUp → GAMESSA_SDK (fallback без haxelib). */
	static function findSource(haxelibDir:Null<String>):Null<String> {
		final marker = "gamessa/script/ServerLogic.hx";

		if (haxelibDir != null) {
			final p = haxelibDir + "/source";
			if (FileSystem.exists(p + "/" + marker))
				return p;
		}

		var dir = Sys.getCwd();
		while (true) {
			final p = dir + "/sdk/gamessa/source";
			if (FileSystem.exists(p + "/" + marker))
				return p;
			final parent = haxe.io.Path.directory(dir);
			if (parent == dir)
				break;
			dir = parent;
		}

		final env = Sys.getEnv("GAMESSA_SDK");
		if (env != null && FileSystem.exists(env + "/" + marker))
			return env;

		return null;
	}
}
