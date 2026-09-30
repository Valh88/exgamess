package spike;

/**
	Спайк «общей логики»: чистые функции над plain-данными, которые
	компилируются и в клиент (hl/js), и в серверный Lua (`haxe -lua`),
	исполняемый VM пакета `lua` внутри BEAM. Эффектов нет — только
	детерминированные вычисления над состоянием.
**/

typedef Player = {x:Float, y:Float, hp:Float, name:String};

class Shared {
	public static inline var RANGE:Float = 3.5;

	// анонимные структуры (форма стейта) + float-арифметика
	public static function inRange(a:Player, b:Player):Bool {
		final dx = a.x - b.x;
		final dy = a.y - b.y;
		return dx * dx + dy * dy <= RANGE * RANGE;
	}

	// мутация структуры-ссылки (Lua-таблица под капотом)
	public static function move(p:Player, dx:Float, dy:Float):Void {
		p.x += dx;
		p.y += dy;
	}

	public static function clamp(v:Float, lo:Float, hi:Float):Float {
		return v < lo ? lo : (v > hi ? hi : v);
	}

	// Array + битовые операции (_hx_bit на Lua 5.3+ — нативные операторы)
	public static function checksum(flags:Array<Bool>):Int {
		final acc:Int = 0;
		var out = acc;
		for (i in 0...flags.length)
			if (flags[i])
				out = out | (1 << i);
		return out;
	}

	// Map (StringMap) как значение-результат
	public static function tag(players:Array<Player>):Map<String, Float> {
		final m = new Map<String, Float>();
		for (p in players)
			m.set(p.name, p.hp);
		return m;
	}

	// String-операции (в `lua`-пакете собственный движок паттернов)
	public static function label(name:String):String {
		return 'p:' + name.toLowerCase() + ':' + name.length;
	}

	// параметр-анонимная структура
	public static function describe(p:{name:String, x:Float, hp:Float}):String {
		return p.name + "@" + Std.string(Std.int(p.x)) + "/" + Std.string(Std.int(p.hp));
	}
}
