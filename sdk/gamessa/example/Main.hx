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

	Эндпоинт — первым аргументом (https/wss работают сами: схема выводится
	из эндпоинта). Проверка сертификата на локальном https-стенде
	(localhost/127.0.0.1, самоподписанный `mix phx.gen.cert`) по умолчанию
	отключена — демо об этом пишет trace'ом. Явно:

	    hl bin/example.hl http://127.0.0.1:4100              # без TLS
	    hl bin/example.hl https://127.0.0.1:4001             # самоподписанный стенд
	    hl bin/example.hl https://my.host --verify-cert      # доверенный CA
	    hl bin/example.hl https://127.0.0.1:4001 --insecure  # как дефолт, явно

	Интерактив: `<текст>` — сказать в канал, `/quit` — выйти.
*/
class Main {
	static final DEFAULT_ENDPOINT = "https://127.0.0.1:4001";

	static function main() {
		#if (js && !nodejs)
		// браузер проверяет сертификат сам (доверие импортируется вручную)
		start(DEFAULT_ENDPOINT, true);
		#else
		var args = Sys.args();
		var endpoint = args.length > 0 ? args[0] : DEFAULT_ENDPOINT;

		var verifyCert:Null<Bool> = null;
		if (args.indexOf("--insecure") >= 0)
			verifyCert = false;
		if (args.indexOf("--verify-cert") >= 0)
			verifyCert = true;
		if (verifyCert == null)
			verifyCert = !isLocalHttps(endpoint);

		#if (hl || eval)
		// Главный поток получает event loop и живёт, пока его не остановит
		// Sys.exit в fail()/onLeave. Колбэки из фоновых потоков (HTTP, WS)
		// маршалим в него: haxe.Timer на sys-таргетах требует event loop
		// потока, а reconnect-логика Room на нём построена.
		sys.thread.Thread.runWithEventLoop(() -> start(endpoint, verifyCert));
		#elseif sys
		start(endpoint, verifyCert);
		while (true)
			Sys.sleep(0.1); // живём до Sys.exit в fail()/onLeave
		#else
		start(endpoint, verifyCert);
		#end
		#end
	}

	/** Локальный https = самоподписанный dev-стенд (`mix phx.gen.cert`). */
	static function isLocalHttps(endpoint:String):Bool {
		var e = endpoint.toLowerCase();
		if (!StringTools.startsWith(e, "https://"))
			return false;
		var host = e.substr(8).split("/")[0].split(":")[0];
		return host == "localhost" || host == "127.0.0.1" || host == "::1";
	}

	static function start(endpoint:String, verifyCert:Bool):Void {
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
		var client = new Client(endpoint, null, null, verifyCert);
		trace('gamessa chat demo → $endpoint (user: $username)' + (verifyCert ? "" : " [verifyCert=false: проверка сертификата отключена]"));

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

	#if !js
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
	#end

	static function fail(err:MatchMakeError):Void {
		trace('ERROR ${err.code}: ${err.message}');
		#if sys
		Sys.exit(1);
		#end
	}
}
