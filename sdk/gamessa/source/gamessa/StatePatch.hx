package gamessa;

import haxe.ds.StringMap;

/**
	Применение дельт состояния комнаты (кадр `ROOM_STATE_PATCH`, opcode 15).

	Payload — msgpack-объект `{"ops": [...]}`, каждая операция:

		{"p": ["players", "sKd8", "x"], "v": 10}   — установить по пути
		{"p": ["players", "ann"],       "d": true} — удалить ключ

	Путь — массив строковых ключей; промежуточные узлы создаются при
	отсутствии. Операции — «присваивания»: безопасно применять к любому
	актуальному срезу состояния. Серверный аналог — `ExGames.Room.StateDiff`.

	`Room.state` хранит дерево в виде АНОНИМНЫХ объектов (`toAnon`/`applyAnon`) —
	только у них прямые поля (`state.score`) работают на всех таргетах;
	StringMap-дерево, как его декодирует MsgPack, для этого непригодно.
	Динамические ключи (map sid → значение) типизируются на клиенте как
	`Dynamic` + `Reflect.field`/доступ по ключу — формат wire от этого не
	зависит.
*/
class StatePatch {
	/**
		Глубоко конвертирует StringMap-дерево в анонимные объекты (массивы
		обходятся, значения внутри них тоже). Идемпотентно: anon/скаляры
		возвращаются как есть. Вызывается Room'ом на полный снапшот
		(`ROOM_STATE`) и при записи поддеревьев из операций патчей.
	*/
	public static function toAnon(value:Dynamic):Dynamic {
		if (Std.isOfType(value, StringMap)) {
			var map:StringMap<Dynamic> = value;
			var out:Dynamic = {};
			for (key in map.keys())
				Reflect.setField(out, key, toAnon(map.get(key)));
			return out;
		}
		if (Std.isOfType(value, Array)) {
			var arr:Array<Dynamic> = value;
			var out = arr.slice(0);
			for (i in 0...out.length)
				out[i] = toAnon(out[i]);
			return out;
		}
		return value;
	}

	/** `apply` для анонимного дерева (представление `Room.state`). */
	public static function applyAnon(state:Dynamic, payload:StringMap<Dynamic>):Dynamic {
		var ops:Array<Dynamic> = payload == null ? null : payload.get("ops");
		if (ops == null)
			return orEmpty(state);

		for (op in ops) {
			var m:StringMap<Dynamic> = op;
			var path:Array<Dynamic> = m.get("p");

			if (m.get("d") == true)
				state = delAtAnon(state, path);
			else
				state = setAtAnon(state, path, toAnon(m.get("v")));
		}

		return orEmpty(state);
	}

	public static function apply(state:Dynamic, payload:StringMap<Dynamic>):Dynamic {
		var ops:Array<Dynamic> = payload == null ? null : payload.get("ops");
		if (ops == null)
			return state;

		for (op in ops) {
			var m:StringMap<Dynamic> = op;
			var path:Array<Dynamic> = m.get("p");

			if (m.get("d") == true)
				state = delAt(state, path);
			else
				state = setAt(state, path, m.get("v"));
		}

		return state;
	}

	static inline function orEmpty(state:Dynamic):Dynamic {
		if (state == null)
			return {};
		return state;
	}

	static function setAtAnon(state:Dynamic, path:Array<Dynamic>, value:Dynamic):Dynamic {
		if (path.length == 0)
			return value;

		// чужое/наследованное представление заменяем своим деревом,
		// конвертируя уже накопленное
		var base:Dynamic;
		if (state == null)
			base = {};
		else if (Std.isOfType(state, StringMap))
			base = toAnon(state);
		else
			base = state;
		return setInAnon(base, path, value);
	}

	static function setInAnon(obj:Dynamic, path:Array<Dynamic>, value:Dynamic):Dynamic {
		var key:String = path[0];

		if (path.length == 1) {
			Reflect.setField(obj, key, value);
			return obj;
		}

		var child:Dynamic = Reflect.field(obj, key);
		if (child == null || Std.isOfType(child, StringMap)) {
			child = child == null ? {} : toAnon(child);
			Reflect.setField(obj, key, child);
		}
		setInAnon(child, path.slice(1), value);
		return obj;
	}

	static function delAtAnon(state:Dynamic, path:Array<Dynamic>):Dynamic {
		if (path.length == 0)
			return null;

		if (state == null || Std.isOfType(state, StringMap))
			return state;

		var key:String = path[0];

		if (path.length == 1) {
			Reflect.deleteField(state, key);
			return state;
		}

		var child:Dynamic = Reflect.field(state, key);
		if (child != null && !Std.isOfType(child, StringMap))
			delAtAnon(child, path.slice(1));

		return state;
	}

	static function setAt(state:Dynamic, path:Array<Dynamic>, value:Dynamic):Dynamic {
		if (path.length == 0)
			return value;

		var base:StringMap<Dynamic> = Std.isOfType(state, StringMap) ? state : new StringMap<Dynamic>();
		return setIn(base, path, value);
	}

	static function setIn(map:StringMap<Dynamic>, path:Array<Dynamic>, value:Dynamic):StringMap<Dynamic> {
		var key:String = path[0];

		if (path.length == 1) {
			map.set(key, value);
			return map;
		}

		var child:Dynamic = map.get(key);
		var childMap:StringMap<Dynamic> = Std.isOfType(child, StringMap) ? child : new StringMap<Dynamic>();
		map.set(key, setIn(childMap, path.slice(1), value));
		return map;
	}

	static function delAt(state:Dynamic, path:Array<Dynamic>):Dynamic {
		if (path.length == 0)
			return null;

		if (!Std.isOfType(state, StringMap))
			return state;

		var key:String = path[0];

		if (path.length == 1) {
			state.remove(key);
			return state;
		}

		var child:Dynamic = state.get(key);
		if (Std.isOfType(child, StringMap))
			delAt(child, path.slice(1));

		return state;
	}
}
