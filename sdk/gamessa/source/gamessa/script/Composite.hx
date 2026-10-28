package gamessa.script;

/**
	Композитный бандл: несколько модулей (наследники `ServerLogic`/`Sync`)
	в ОДНОМ Lua-чанке и одной VM. Модули пишутся как обычно — свой typedef
	состояния, свои init/call/tick/@:rpc; бандл собирает их в общий
	контракт `M` (init/call/tick/schema), который обслуживает мост
	`ExGames.Room.Logics.Lua` без изменений — для него это «один скрипт
	на комнату».

	    // server_scripts/mygame/Bundle.hx  (-main этой сборки)
	    class Bundle {
	        static function main()
	            gamessa.script.Composite.build([
	                { key: "physics", logic: new PhysicsLogic() },
	                { key: "economy", logic: new EconomyLogic() },
	            ]);
	    }

	Сборка — ОДНА компиляция `haxe -lua bundle.lua -main Bundle`
	(`mix ex_games.scripts` детектит `Composite.build`): один рантайм
	Haxe на все модули, один файл (песочница VM запрещает `require`).

	Контракт поверх модулей:

	* состояние — общий документ `{key1: <state модуля 1>, key2: …}`;
	  каждый модуль получает ТОЛЬКО свой слайс и мутирует его на месте;
	* `M.init(a)` → init каждого модуля в его слайс;
	* `M.call("join"/"leave"/"info", …)` → всем модулям по порядку, эффекты
	  конкатенируются (info — эффект `NotifyRoom` соседа: доставляется
	  всем, включая отправителя — фильтрует по содержимому msg);
	* `M.call(message/request)` → модулю-владельцу: первый, чья
	  `messages()` содержит тип; `messages(): ["*"]` — catch-all,
	  проверяется последним; request идёт в `reply` (значение-ответ),
	  null → мост ответит «нет обработчика»;
	* `M.tick(dt, s)` → все модули по порядку объявления (эффекты тиков
	  не идут — как у одиночного скрипта);
	* `M.schema.messages` — объединение (без "*"), `M.schema.state` —
	  `{key = <__stateLua модуля>}`: гейт `set_state` комнаты валидирует
	  общий документ, клиентский `Sync.stateKey` режет свою ветку.

	Ключ ветки модуля: явный `key` из записи → `instance.stateKey`
	(поле `Sync`) → короткое имя класса. Дубликаты/пустой список — ошибка
	сборки. Схемы/диспетчеризация тестопригодны без Lua (interp) —
	lua-специфична только публикация `M` в `build()`.
*/
@:keep
class Composite
{
	public static function build(entries:Array<CompositeEntry>):Void
	{
		if (entries == null || entries.length == 0)
			throw "Composite: пустой список модулей";

		modules = [for (e in entries) resolve(e)];

		// дубликаты ключей = ветки состояния затирали бы друг друга
		final seen = new Map<String, Bool>();
		for (m in modules) {
			if (seen.exists(m.key))
				throw 'Composite: дубликат ключа ветки "${m.key}"';
			seen.set(m.key, true);
		}

		#if lua
		// __lua__ инлайнит только КОНСТАНТУ: вся динамика — в вызовах
		// статиков этого класса из Lua-кода, литерал константный
		untyped __lua__("
M = {}
function M.init(a) return __hx_toplain(__gamessa_script_Composite.__initWire(a)) end
function M.call(fn, a, s) return __hx_toplain(__gamessa_script_Composite.__callWire(fn, a, s)), __hx_toplain(s) end
function M.tick(dt, s) __gamessa_script_Composite.__tickWire(dt, s); return nil, __hx_toplain(s) end
M.schema = { messages = __hx_toplain(__gamessa_script_Composite.__messagesWire()), state = __hx_toplain(__gamessa_script_Composite.__stateSchemaWire()) }
");
		#end
	}

	// ------------------------------------------------------------------
	// Входы из Lua-биндинга (и напрямую из юнит-тестов)
	// ------------------------------------------------------------------

	/** init всех модулей → общий документ состояния. */
	public static function __initWire(args:Dynamic):Dynamic
	{
		final doc:Dynamic = {};
		for (m in modules)
			Reflect.setField(doc, m.key, Reflect.callMethod(m.cls, Reflect.field(m.cls, "__wire"), [m.logic, "init", args, null]));
		return doc;
	}

	/** Развёртка wire-вызова по модулям (см. контракт в документации класса). */
	public static function __callWire(fn:String, args:Dynamic, state:Dynamic):Dynamic
	{
		final wire:ScriptFn = ScriptWire.fromWire(fn, args);

		return switch (wire)
		{
			// join/leave/info — всем модулям по порядку, эффекты конкатенируются
			// (info: зеркалит доставку logic_info ВСЕХ логик комнаты; отправитель
			// тоже получит своё — фильтрует по содержимому msg)
			case ScriptFn.Join(_, _) | ScriptFn.Leave(_, _) | ScriptFn.Info(_):
				// пустой список → null: [] после toplain декодируется как {}
				// (мост ждёт список эффектов или nil)
				nonEmpty(concatEffects([for (m in modules) callModule(m, wire, state)]));

			case ScriptFn.Request(type, _, _):
				switch (ownerOf(type))
				{
					case null: null; // мост ответит «нет обработчика»
					case m: Reflect.callMethod(m.cls, Reflect.field(m.cls, "__wire"), [m.logic, fn, args, slice(state, m.key)]);
				}

			case ScriptFn.Message(type, _, _):
				switch (ownerOf(type))
				{
					case null: null;
					case m: nonEmpty(Reflect.callMethod(m.cls, Reflect.field(m.cls, "__wire"), [m.logic, fn, args, slice(state, m.key)]));
				}
		}
	}

	/** Тик: все модули по порядку объявления (пайплайн). */
	public static function __tickWire(dt:Float, state:Dynamic):Void
	{
		for (m in modules)
			Reflect.callMethod(m.cls, Reflect.field(m.cls, "__wire"), [m.logic, "tick", dt, slice(state, m.key)]);
	}

	/** Объединение messages() модулей (без catch-all "*"). */
	public static function __messagesWire():Array<String>
	{
		final out:Array<String> = [];
		for (m in modules)
			for (type in m.messages)
				if (type != "*" && out.indexOf(type) < 0)
					out.push(type);
		return out;
	}

	/** Merged state-схема: `{key1: <__stateSchema модуля 1>, …}` (Haxe-значение). */
	public static function __stateSchemaWire():Dynamic
	{
		final doc:Dynamic = {};
		for (m in modules)
			Reflect.setField(doc, m.key, Reflect.field(m.cls, "__stateSchema"));
		return doc;
	}

	// ------------------------------------------------------------------
	// Внутреннее (чистое — тестируется на interp)
	// ------------------------------------------------------------------

	static var modules:Array<ResolvedModule> = [];

	static function resolve(e:CompositeEntry):ResolvedModule
	{
		final cls = Type.getClass(e.logic);
		if (cls == null)
			throw "Composite: модуль без класса";

		final key = e.key != null
			? e.key
			: (Reflect.field(e.logic, "stateKey") != null
				? Reflect.field(e.logic, "stateKey")
				: shortName(cls));

		final messages:Array<String> = cast (Reflect.field(cls, "messages") != null
			? Reflect.callMethod(cls, Reflect.field(cls, "messages"), [])
			: []);

		return {
			key: key,
			cls: cls,
			logic: e.logic,
			messages: messages,
			wildcard: messages.indexOf("*") >= 0
		};
	}

	/** Владелец типа: первый с объявленным типом, затем первый catch-all. */
	static function ownerOf(type:String):Null<ResolvedModule>
	{
		for (m in modules)
			if (!m.wildcard && m.messages.indexOf(type) >= 0)
				return m;
		for (m in modules)
			if (m.wildcard)
				return m;
		return null;
	}

	static function callModule(m:ResolvedModule, wire:ScriptFn, state:Dynamic):Dynamic
	{
		final fn:String = switch (wire)
		{
			case ScriptFn.Join(_, _): "join";
			case ScriptFn.Leave(_, _): "leave";
			case ScriptFn.Message(type, _, _): type;
			case ScriptFn.Request(type, _, _): type;
			case ScriptFn.Info(_): "info";
		};
		return Reflect.callMethod(m.cls, Reflect.field(m.cls, "__wire"), [m.logic, fn, wireArgs(wire), slice(state, m.key)]);
	}

	// wire-fn аргументы: join/leave = [sid, X]; message/request = [type, sid, payload];
	// info = [msg]. Ключи — ЧИСЛОВЫЕ на lua: ScriptWire.get читает args[i]
	// числом (мост кодирует список аргументов 1-based таблицей);
	// Reflect.setField писал бы строковые "1".."3" — на Lua они мимо.
	static function wireArgs(wire:ScriptFn):Dynamic
	{
		final args:Dynamic = {};
		final set = (i:Int, v:Dynamic) ->
			#if lua
			(untyped args[i] = v)
			#else
			Reflect.setField(args, Std.string(i), v)
			#end;
		switch (wire)
		{
			case ScriptFn.Join(sid, x):
				set(1, sid);
				set(2, x);
			case ScriptFn.Leave(sid, x):
				set(1, sid);
				set(2, x);
			case ScriptFn.Message(type, sid, p):
				set(1, type);
				set(2, sid);
				set(3, p);
			case ScriptFn.Request(type, sid, p):
				set(1, type);
				set(2, sid);
				set(3, p);
			case ScriptFn.Info(msg):
				set(1, msg);
		}
		return args;
	}

	static function slice(state:Dynamic, key:String):Dynamic
	{
		if (state == null)
			return null;
		final s = Reflect.field(state, key);
		return s == null ? null : s;
	}

	static function concatEffects(lists:Array<Dynamic>):Array<Dynamic>
	{
		final out:Array<Dynamic> = [];
		for (fx in lists)
			if (fx != null)
				for (effect in (fx : Array<Dynamic>))
					out.push(effect);
		return out;
	}

	/** [] → null: пустой список после toplain декодируется как {} (map). */
	static function nonEmpty(fx:Array<Dynamic>):Array<Dynamic>
	{
		return (fx == null || fx.length == 0) ? null : fx;
	}

	static function shortName(cls:Class<Dynamic>):String
	{
		final full = Type.getClassName(cls);
		return full.substr(full.lastIndexOf(".") + 1);
	}
}

/** Запись сборки: модуль + (опционально) ключ его ветки состояния. */
typedef CompositeEntry = {
	?key:String,
	logic:ServerLogic<Dynamic>,
}

/** Разрешённый модуль (после build). */
private typedef ResolvedModule = {
	key:String,
	cls:Class<Dynamic>,
	logic:ServerLogic<Dynamic>,
	messages:Array<String>,
	wildcard:Bool,
}
