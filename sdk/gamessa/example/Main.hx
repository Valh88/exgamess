package example;

import gamessa.Client;
import gamessa.MatchMakeError;
import gamessa.Room;
import gamessa.SeatReservation;
import gamessa.util.Dispatcher;
import haxe.ds.StringMap;

/**
	Демо: чат поверх сервера ExGames (демо-комната "chat" из arena_example).

	Запуск (сервер должен быть поднят, например `PORT=4100 mix phx.server`
	в корне репозитория):

	    haxe example.hxml -hl bin/example.hl   && hl bin/example.hl
	    haxe example.hxml -neko bin/example.n  && neko bin/example.n

	Интерактив: `<текст>` — сказать в канал, `/quit` — выйти.
*/
class Main {
	static final ENDPOINT = "http://127.0.0.1:4100";

	static function main() {
		#if (hl || eval)
		// Главный поток получает event loop и живёт, пока его не остановит
		// Sys.exit в fail()/onLeave. Колбэки из фоновых потоков (HTTP, WS)
		// маршалим в него: haxe.Timer на sys-таргетах требует event loop
		// потока, а reconnect-логика Room на нём построена.
		sys.thread.Thread.runWithEventLoop(start);
		#elseif sys
		start();
		while (true)
			Sys.sleep(0.1); // живём до Sys.exit в fail()/onLeave
		#else
		start();
		#end
	}

	static function start():Void {
		#if sys
		var pending:Array<Void->Void> = [];
		var lock = new sys.thread.Mutex();
		Dispatcher.post = f -> {
			lock.acquire();
			pending.push(f);
			lock.release();
		};
		pump(pending, lock);
		#end

		var username = "haxe_" + Std.int(Math.random() * 100000);
		var password = "secret123";
		var client = new Client(ENDPOINT);
		trace('gamessa chat demo → $ENDPOINT (user: $username)');

		client.register(username, password, auth -> {
			trace("registered, token received");
			client.joinOrCreate("chat", {channel: "global"}, res -> runChat(client, res), fail);
		}, fail);
	}

	#if sys
	static function pump(pending:Array<Void->Void>, lock:sys.thread.Mutex):Void {
		var batch:Array<Void->Void>;
		lock.acquire();
		batch = pending.splice(0, pending.length);
		lock.release();
		for (fn in batch)
			fn();
		haxe.Timer.delay(() -> pump(pending, lock), 1);
	}
	#end

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
					var who:Dynamic = m.get("username");
					if (who == null)
						who = m.get("from");
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
			#if sys
			Sys.exit(0);
			#end
		});

		#if (js && !nodejs)
		// браузер: ввод подключается из index.html
		#else
		sys.thread.Thread.create(() -> interactiveLoop(room));
		#end
	}

	static function interactiveLoop(room:Room):Void {
		var stdin = Sys.stdin();
		Sys.println('type a message and press Enter ("/quit" to leave):');

		while (true) {
			var line = stdin.readLine();
			var text = StringTools.trim(line);
			if (text == "/quit") {
				// leave тоже через Dispatcher — без записи в сокет из двух потоков
				Dispatcher.post(() -> room.leave());
				return;
			}
			if (text != "")
				Dispatcher.post(() -> room.send("say", {text: text}));
		}
	}

	static function fail(err:MatchMakeError):Void {
		trace('ERROR ${err.code}: ${err.message}');
		#if sys
		Sys.exit(1);
		#end
	}
}
