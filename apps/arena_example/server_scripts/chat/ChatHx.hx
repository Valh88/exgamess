package;

import gamessa.script.Effect;
import gamessa.script.ScriptArgs;

/**
	Чат на Haxe через gamessa.script.ServerLogic (пример арены, тип комнаты
	"haxe_chat"). Вся машинерия контракта M — биндинг, нормализация границ,
	схема из typedef-а — генерируется билдером SDK; здесь только логика.

	Сборка: cd priv/haxe && haxe build.hxml   -> ../lua/chat_haxe.lua
	Схема после правки типов: mix ex_games.lua_schema priv/lua/chat_haxe.lua
	Обновление логики: пересборка -> новые комнаты на новом чанке (живые
	держат старую VM — перезапуск через dispose); VERSION видна клиентам
	в payload "joined".
**/

// тип состояния = схема: билдер выводит M.schema.state из ChatState
typedef ChatMsg = {n:Int, sid:String, name:String, text:String};

typedef ChatState = {
	seq:Int,
	version:Int,
	users:haxe.DynamicAccess<String>,
	history:haxe.DynamicAccess<ChatMsg>,
};

class ChatHx extends gamessa.script.ServerLogic<ChatState> {
	public static inline var VERSION = 1;
	static inline var HISTORY_MAX = 30;

	/** Типы сообщений для маршрутизации моста (M.schema.messages). */
	public static function messages():Array<String>
		return ["say", "history"];

	override function init(_args:Dynamic):ChatState
		return {seq: 0, version: VERSION, users: {}, history: {}};

	// join    -> args: [sid, auth]
	// message -> args: [type, sid, payload]
	override function call(fn:String, args:ScriptArgs, state:ChatState):Array<Effect> {
		if (fn == "join") {
			final sid:String = args.get(1);
			final auth:Dynamic = args.get(2);
			final name:String = usernameOf(auth);
			Reflect.setField(state.users, sid, name);
			return [Broadcast("joined", {sid: sid, name: name, v: VERSION})];
		}

		if (fn == "leave") {
			final sid:String = args.get(1);
			// deleteField на plain-таблицах падает — setField(null) = rawset(nil)
			Reflect.setField(state.users, sid, null);
			return [Broadcast("left", {sid: sid})];
		}

		if (fn == "message") {
			final sid:String = args.get(2);
			final payload:Dynamic = args.get(3);

			if (args.get(1) == "say") {
				state.seq = state.seq + 1;
				final n:Int = state.seq;
				final name:String = usernameOf(Reflect.field(state.users, sid));
				Reflect.setField(state.history, Std.string(n), {n: n, sid: sid, name: name, text: payload.text});

				// окно истории: строковые ключи-seq, старые удаляем
				if (n > HISTORY_MAX)
					Reflect.setField(state.history, Std.string(n - HISTORY_MAX), null);

				return [Broadcast("say", {n: n, sid: sid, name: name, text: payload.text})];
			}

			if (args.get(1) == "history") {
				// личная доставка: эффект send_to вместо broadcast
				return [SendTo(sid, "history", {history: state.history})];
			}
		}

		return null;
	}

	override function tick(_dt:Float, _state:ChatState):Void {}

	static function usernameOf(v:Dynamic):String {
		final name:Dynamic = Reflect.field(v, "username");
		return name == null ? (v == null ? "anon" : Std.string(v)) : Std.string(name);
	}
}
