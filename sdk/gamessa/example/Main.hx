package example;

import gamessa.Client;
import gamessa.MatchMakeError;
import gamessa.Room;
import gamessa.SeatReservation;
import haxe.ds.StringMap;

/**
	Демо: чат поверх сервера ExGames (arena_example: комната "chat").

	Запуск (сервер должен быть поднят, например `PORT=4100 mix phx.server`
	в корне репозитория):

	    haxe example.hxml            # JS (браузер) — см. index.html
	    haxe -cp source -cp example -lib hxWebSockets -neko bin/example.n example.Main
	    neko bin/example.n           # интерактивный чат в консоли

	Интерактив: `<текст>` — сказать в канал, `/quit` — выйти.
*/
class Main {
	static final ENDPOINT = "http://127.0.0.1:4100";

	static function main() {
		var username = "haxe_" + Std.int(Math.random() * 100000);
		var password = "secret123";

		var client = new Client(ENDPOINT);
		trace('gamessa chat demo → $ENDPOINT (user: $username)');

		client.register(username, password, auth -> {
			trace("registered, token received");
			client.joinOrCreate("chat", {channel: "global"}, res -> runChat(client, res), fail);
		}, fail);
	}

	static function runChat(client:Client, reservation:SeatReservation):Void {
		var room = client.connectRoom(reservation);

		room.onJoin.add(e -> {
			trace('joined room ${room.roomId} as ${room.sessionId}');
			trace('reconnection token: ${room.reconnectionToken}');
			room.send("say", {text: "hello from gamessa!"});
		});

		room.onMessage.add(e -> {
			switch (e.type) {
				case "say":
					var m:StringMap<Dynamic> = e.message;
					var who:String = m.get("username");
					trace('<$who> ${m.get("text")}');
				case "joined":
					var m:StringMap<Dynamic> = e.message;
					trace('* ${m.get("username")} joined');
				case "left":
					var m:StringMap<Dynamic> = e.message;
					trace('* ${m.get("session_id")} left');
				case _:
					// прочие типы игнорируем
			}
		});

		room.onError.add(e -> trace('room error ${e.code}: ${e.message}'));
		room.onDrop.add(_ -> trace("connection lost, reconnecting..."));
		room.onLeave.add(e -> {
			trace('left the room (${e.code} ${e.reason})');
			Sys.exit(0);
		});

		#if (js && !nodejs)
		// браузер: кнопка/инпут подключаются в index.html
		#else
		interactiveLoop(room);
		#end
	}

	static function interactiveLoop(room:Room):Void {
		var stdin = Sys.stdin();
		Sys.println('type a message and press Enter ("/quit" to leave):');

		while (true) {
			var line = stdin.readLine();
			if (StringTools.trim(line) == "/quit") {
				room.leave();
				return;
			}
			if (StringTools.trim(line) != "")
				room.send("say", {text: line});
		}
	}

	static function fail(err:MatchMakeError):Void {
		trace('ERROR ${err.code}: ${err.message}');
		Sys.exit(1);
	}
}
