package gamessa.script;

/**
	Аргументы вызова скрипта (M.call(fn, args, state)): host-таблицы из
	Elixir-документов — **1-based plain-таблицы**, поэтому доступ через
	`args.get(1)` (первый элемент). Сырой Dynamic — `args.raw()`.

	Позиции от моста ExGames.Room.Logics.Lua:
	  join    -> get(1) = sid,      get(2) = auth
	  leave   -> get(1) = sid,      get(2) = reason
	  message -> get(1) = type,     get(2) = sid, get(3) = payload
**/
abstract ScriptArgs(Dynamic) from Dynamic {
	/** 1-based доступ к элементу. */
	public inline function get(i:Int):Dynamic
		#if lua
		return untyped this[i];
		#else
		return Reflect.field(this, Std.string(i));
		#end

	/** Сырая host-таблица (plain, 1-based; методы Haxe Array неприменимы). */
	public inline function raw():Dynamic
		return this;

	/** Фабрика для клиентского переиспользования (предикт): из обычного массива. */
	public static function ofArray(a:Array<Dynamic>):ScriptArgs {
		final o:Dynamic = {};
		for (i in 0...a.length)
			#if lua
			untyped o[i + 1] = a[i];
			#else
			Reflect.setField(o, Std.string(i + 1), a[i]);
			#end
		return o;
	}
}
