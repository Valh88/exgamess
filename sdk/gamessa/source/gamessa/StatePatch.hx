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
*/
class StatePatch {
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
