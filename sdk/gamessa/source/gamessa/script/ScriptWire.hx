package gamessa.script;

/**
	Развёртка wire-вызова моста (`fn:String` + 1-based таблица аргументов)
	в типизированный ScriptFn. Вызывается только из Lua-биндинга
	(генерируется билдером в `__callWire`).

	Нюанс: разбор через if/else, а не switch-выражение — вызов конструктора
	enum с переменными-аргументами внутри case'ов switch'а даёт в haxe
	ложное «Too many arguments» (наблюдалось на 4.3.7, lua и interp).
**/
class ScriptWire
{
	public static function fromWire(fn:String, args:Dynamic):ScriptFn
	{
		// wire-args: join/leave = [sid, X]; message = [type, sid, payload]
		final a1:Dynamic = get(args, 1);
		final a2:Dynamic = get(args, 2);
		final a3:Dynamic = get(args, 3);

		if (fn == "join")
			return ScriptFn.Join(a1, a2);

		if (fn == "leave")
			return ScriptFn.Leave(a1, a2);

		if (fn == "request")
			return ScriptFn.Request(a1, a2, a3);

		// неизвестный вид — совместимость вперёд: fn как тип кадра
		return ScriptFn.Message(if (fn == "message") a1 else fn, a2, a3);
	}

	/** true для Request-вызова (мост ждёт значение-ответ, не эффекты). */
	public static function isRequest(fn:ScriptFn):Bool
		return switch (fn)
		{
			case ScriptFn.Request(_, _, _): true;
			case _: false;
		}

	/** 1-based доступ к host-таблице аргументов. */
	static function get(args:Dynamic, i:Int):Dynamic
		#if lua
		return untyped (args[i]);
		#else
		return Reflect.field(args, Std.string(i));
		#end
}
