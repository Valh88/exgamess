package;

import spike.Shared;

/**
	Самопроверка общего кода прямо под Lua: main() выполняется при загрузке
	чанка VM пакета `lua`; результаты — строки "SPIKE <name> OK|FAIL",
	которые читает Elixir-тест haxe_lua_spike_test.exs.
**/
class Main {
	static var failed = 0;

	static function check(name:String, cond:Bool) {
		if (!cond)
			failed++;
		Sys.println('SPIKE $name ${cond ? "OK" : "FAIL"}');
	}

	static function main() {
		final a:spike.Player = {x: 0.0, y: 0.0, hp: 100, name: "Alpha"};
		final b:spike.Player = {x: 3.0, y: 0.0, hp: 50, name: "Beta"};

		check("inRange", Shared.inRange(a, b));

		Shared.move(a, 1.5, 2.5);
		check("move", a.x == 1.5 && a.y == 2.5);

		check("clamp", Shared.clamp(5.7, 0, 5) == 5);
		check("checksum", Shared.checksum([true, false, true]) == 5);

		final tags = Shared.tag([a, b]);
		check("map", tags.get("Alpha") == 100 && tags.exists("Beta"));

		check("string", Shared.label("Alpha") == "p:alpha:5");
		check("anon", Shared.describe(b) == "Beta@3/50");

		// кросс-проверка float-детерминизма: 0.1+0.2 не равно 0.3 нигде
		check("float", (0.1 + 0.2) != 0.3);

		Sys.println('SPIKE failed=$failed');
	}
}
