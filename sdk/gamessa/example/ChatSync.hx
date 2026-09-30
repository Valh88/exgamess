package example;

import gamessa.script.Effect;

typedef SyncMsg =
{
	n:Int,
	sid:String,
	text:String
};

typedef SyncState =
{
	seq:Int,
	version:Int,
	users:haxe.DynamicAccess<String>,
	history:haxe.DynamicAccess<SyncMsg>,
};

/**
	Клиентская половина sync-чата — зеркало серверного
	apps/arena_example/server_scripts/chatsync/ChatSync.hx (тот же
	typedef состояния, те же имена @:rpc). Один и тот же класс собирается
	и в Lua-чанк (`-D gamessa-server`, тела выполняются), и сюда — где
	имена становятся типизированными стабами: `chat.say(text)` →
	`room.send("say", …)`, `chat.seq(v -> …)` → `room.request("seq", …)`.

	Демо: `hl bin/example.hl <endpoint> sync_chat` (Main.hx).
**/
class ChatSync extends gamessa.script.Sync<SyncState>
{
	public static inline var VERSION = 2;

	@:rpc public function say(text:String):Array<Effect>
		return [
			Broadcast("say",
				{
					n: 0,
					sid: caller,
					name: "",
					text: text
				})
		];

	@:rpc public function seq():Int
		return 0;

	@:rpc public function history():Dynamic
		return null;
}
