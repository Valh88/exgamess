package gamessa.script;

/**
	Компилятор-макрос: типизированный `Room<S>` для Lua-комнат.

	Источник правды — `M.schema` Lua-скрипта. Серверная задача
	`mix ex_games.lua_schema priv/lua/arena.lua` извлекает схему в
	JSON-артефакт (`arena.schema.json`, коммитится); этот макрос читает
	артефакт на компиляции и генерирует в модуль аннотированного класса:

	  * `typedef <Prefix>State` — анонимную структуру состояния;
	  * `class <Prefix>Msg` — static inline имена сообщений (String).

	Использование:

		@:build(gamessa.script.Schema.build("arena.schema.json", "LuaArena"))
		class LuaArenaScript {}

		var room:Room<LuaArenaState> = client.joinById(...);
		room.send(LuaArenaMsg.Move, {x: 1, y: 0});
		var hp = room.state.players[sid].hp; // players — DynamicAccess<...>

	Путь к JSON резолвится относительно файла аннотированного класса
	(или как есть, если это абсолютный/полный путь).

	Схема → Haxe:

	  * `"string" | "number" | "boolean"` → `String | Float | Bool`;
	  * `"any"` или неизвестная форма → `Dynamic`;
	  * `{"list": S}` → `Array<T>`;
	  * `{"map": S}` → `haxe.DynamicAccess<T>` (ключи произвольны; стейт
	    комнаты на клиенте — анонимные объекты, см. `StatePatch.toAnon`);
	  * таблица полей → анонимная структура (вложенные структуры инлайнятся).
**/
#if macro
import haxe.Json;
import haxe.macro.Context;
import haxe.macro.Expr;
import sys.FileSystem;
import sys.io.File;
#end

class Schema {
	#if macro

	/** Читает схему и генерирует типы в модуль аннотированного класса. */
	public static function build(path:String, ?prefix:String):Array<Field> {
		prefix = prefix == null ? "Script" : prefix;

		var schema:Dynamic = Json.parse(File.getContent(resolve(path)));
		var pos = Context.currentPos();
		var moduleName = Context.getLocalModule();
		var pack = moduleName.split(".");
		pack.pop();

		var state:Dynamic = Reflect.field(schema, "state");
		if (state != null) {
			// typedef добавляется в модуль аннотированного класса
			Context.defineType({
				pack: pack,
				name: prefix + "State",
				pos: pos,
				kind: TDAlias(haxeStateType(state, pos)),
				fields: []
			});
		}

		var messages:Array<Dynamic> = Reflect.field(schema, "messages");
		if (messages != null && messages.length > 0) {
			var msgFields:Array<Field> = [];
			for (raw in messages) {
				var name:String = Std.string(raw);
				var value:String = name;
				msgFields.push({
					name: toIdentifier(name),
					kind: FVar(macro :String, macro $v{value}),
					access: [APublic, AStatic, AInline],
					pos: pos
				});
			}

			Context.defineType({
				pack: pack,
				name: prefix + "Msg",
				pos: pos,
				kind: TDClass(),
				fields: msgFields
			});
		}

		return [];
	}

	/** Путь относительно файла аннотированного класса (или как есть). */
	static function resolve(path:String):String {
		if (FileSystem.exists(path))
			return path;

		var here = Context.getPosInfos(Context.currentPos()).file;
		var dir = here.split("\\").join("/").split("/").slice(0, -1).join("/");
		var candidate = dir + "/" + path;

		if (FileSystem.exists(candidate))
			return candidate;

		return Context.fatalError('schema json not found: $path (also tried $candidate)', Context.currentPos());
	}

	static function haxeStateType(spec:Dynamic, pos:Position):ComplexType {
		if (spec == null)
			return macro :Dynamic;

		if (Std.isOfType(spec, String)) {
			return switch (cast(spec, String)) {
				case "string": macro :String;
				case "number": macro :Float;
				case "boolean": macro :Bool;
				case _: macro :Dynamic;
			}
		}

		if (Type.typeof(spec) == TObject) {
			var list = Reflect.field(spec, "list");
			var map = Reflect.field(spec, "map");

			if (list != null) {
				var inner = haxeStateType(list, pos);
				return macro :Array<$inner>;
			}
			if (map != null) {
				var inner = haxeStateType(map, pos);
				return macro :haxe.DynamicAccess<$inner>;
			}

			var fields:Array<Field> = [];
			for (key in Reflect.fields(spec)) {
				fields.push({
					name: key,
					kind: FVar(haxeStateType(Reflect.field(spec, key), pos), null),
					pos: pos
				});
			}
			return TAnonymous(fields);
		}

		return macro :Dynamic;
	}

	/** "player_joined" → "PlayerJoined" (валидный идентификатор Haxe). */
	static function toIdentifier(name:String):String {
		var out = new StringBuf();
		var upper = true;
		for (i in 0...name.length) {
			var c = name.charAt(i);
			if (c == "_" || !isIdentChar(c)) {
				upper = true;
			} else {
				out.add(upper ? c.toUpperCase() : c);
				upper = false;
			}
		}
		var s = out.toString();
		return s.length == 0 ? "Msg" : s;
	}

	static function isIdentChar(c:String):Bool {
		var code = c.charCodeAt(0);
		return (code >= 97 && code <= 122) || (code >= 65 && code <= 90) || (code >= 48 && code <= 57);
	}
	#end
}
