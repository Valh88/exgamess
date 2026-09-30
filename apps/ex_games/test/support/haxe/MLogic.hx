package;

/**
	Haxe-логика с контрактом M моста ExGames.Room.Logics.Lua — фикстура
	для lua_adapter_test / room_logics_lua_test (опция haxe: true).

	Правила Haxe-серверных скриптов (проверены спайком):
	  * @:keep обязателен — иначе DCE вырежет init/call/tick, на которые
	    ссылается только __lua__-биндинг (строки не видны DCE);
	  * чистые функции над документами: мутируем переданный state-таблицу,
	    эффекты возвращаем массивом; сборку {effects, state} делает Lua-обвязка
	    в main() (Haxe не умеет множественные возвраты Lua);
	  * ГРАБЛЯ индексации: Haxe хранит свои массивы 0-based, host-таблицы из
	    Elixir-документов — 1-based plain-таблицы. Аргументы моста типизировать
	    Dynamic и индексировать с 1; .length на host-массивах не читать;
	  * класс без пакета — локальная таблица `MLogic` (упакованные классы —
	    глобальные `__<package>_<Class>`).

	Регенерация чанка: cd test/support/haxe && haxe build.hxml
**/
@:keep
class MLogic {
	// state = { count: число, joins: {sid: true} }
	public static function init(_args:Array<Dynamic>):Dynamic {
		return { count: 0, joins: {} };
	}

	// fn: "join" | "leave" | "message". ГРАБЛЯ: host-массивы из Elixir-документов —
	// plain-таблицы 1-based; типизируем args как Dynamic и индексируем с 1
	// (тип Array<Dynamic> дал бы сырые 0-based индексы Haxe-хранилища).
	//   join    -> [sid, auth]
	//   message -> [type, sid, payload]
	public static function call(fn:String, args:Dynamic, state:Dynamic):Array<Dynamic> {
		if (fn == "join") {
			final sid:String = args[1];
			Reflect.setField(state.joins, sid, true);
			return [["broadcast", "haxe_joined", {sid: sid}]];
		}
		if (fn == "message" && args[1] == "add") {
			final payload:Dynamic = args[3];
			state.count = state.count + payload.n;
			return [["broadcast", "added", {total: state.count}]];
		}
		return null;
	}

	public static function tick(_dt:Float, _state:Dynamic):Void {}

	// Lua-обвязка: собирает контракт M поверх Haxe-функций. Класс без пакета
	// компилируется в ЛОКАЛЬНУЮ таблицу `MLogic` (упакованные классы — в
	// глобальные `__<package>_<Class>`, напр. __gamelogic_Arena); main()
	// исполняется при загрузке чанка и видит локаль того же файла.
	// __hx_toplain (из шимов) нормализует Haxe-структуры (0-based массивы,
	// объекты с __fields__) в plain-документы на КАЖДОЙ границе — иначе
	// служебные ключи уедут в state/эффекты.
	static function main() {
		untyped __lua__("M = {}");
		untyped __lua__("function M.init(a) return __hx_toplain(MLogic.init(a)) end");
		untyped __lua__("function M.call(fn, a, s) return __hx_toplain(MLogic.call(fn, a, s)), __hx_toplain(s) end");
		untyped __lua__("function M.tick(dt, s) MLogic.tick(dt, s); return nil, __hx_toplain(s) end");
		untyped __lua__("M.schema = { messages = { 'add' } }");
	}
}
