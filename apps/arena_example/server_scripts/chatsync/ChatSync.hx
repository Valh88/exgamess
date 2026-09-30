package;

import gamessa.script.Effect;

/**
	Чат на Haxe через gamessa.script.Sync — типизированные @:rpc поверх
	ServerLogic (пример арены, тип комнаты "sync_chat"). Один и тот же
	класс компилируется в Lua-чанк (сервер, `mix ex_games.scripts`) и в
	клиент (js/hl): на сервере тела @:rpc выполняются, на клиенте имена
	становятся стабами (say → room.send, seq/history → room.request).

	Сборка: mix ex_games.scripts        -> ../priv/lua/chatsync/ChatSync.lua
	Обновление логики: пересборка -> новые комнаты на новом чанке (живые
	держат старую VM — перезапуск через dispose); VERSION виден клиентам
	в payload "joined".
**/

typedef SyncMsg = {n:Int, sid:String, text:String};

typedef SyncState = {
	seq:Int,
	version:Int,
	users:haxe.DynamicAccess<String>,
	history:haxe.DynamicAccess<SyncMsg>,
};

class ChatSync extends gamessa.script.Sync<SyncState> {
	public static inline var VERSION = 2;
	static inline var HISTORY_MAX = 30;

	override function init(_args:Dynamic):SyncState
		return {seq: 0, version: VERSION, users: {}, history: {}};

	// --- @:rpc: send-методы (Void | Array<Effect>) -------------------------

	@:rpc public function say(text:String):Array<Effect> {
		state.seq = state.seq + 1;
		final n:Int = state.seq;
		final name:String = usernameOf(Reflect.field(state.users, caller));

		Reflect.setField(state.history, Std.string(n), {n: n, sid: caller, text: text});
		if (n > HISTORY_MAX)
			Reflect.setField(state.history, Std.string(n - HISTORY_MAX), null);

		return [Broadcast("say", {n: n, sid: caller, name: name, text: text})];
	}

	// --- @:rpc: request-методы (любой другой возврат) ----------------------

	@:rpc public function seq():Int
		return state.seq;

	@:rpc public function history():Dynamic
		return state.history;

	// --- события ----------------------------------------------------------

	override function onJoin(sid:String, auth:Dynamic):Array<Effect> {
		final name:String = usernameOf(auth);
		Reflect.setField(state.users, sid, name);
		return [Broadcast("joined", {sid: sid, name: name, v: VERSION})];
	}

	override function onLeave(sid:String, _reason:String):Array<Effect> {
		// deleteField на plain-таблицах падает — setField(null) = rawset(nil)
		Reflect.setField(state.users, sid, null);
		return [Broadcast("left", {sid: sid})];
	}

	static function usernameOf(v:Dynamic):String {
		final name:Dynamic = Reflect.field(v, "username");
		return name == null ? "anon" : Std.string(name);
	}
}
