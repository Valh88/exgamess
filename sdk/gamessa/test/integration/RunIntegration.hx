package;

import gamessa.Client;
import gamessa.util.Dispatcher;
import utest.Runner;
import utest.ui.Report;

/**
	Интеграционные тесты против живого сервера (PORT=4100, `mix phx.server`
	в корне репозитория). Если сервер не поднят — тесты пропускаются.
	Эндпоинт переопределяется переменной GAMESSA_ENDPOINT (например
	`GAMESSA_ENDPOINT=https://localhost:4001` — самоподписанный dev-стенд).

	    haxe test_integration.hxml   # interp; варианты -neko/-hl/-js в файле
*/
class RunIntegration {
	static var failedCount:Int = 0;

	static function main() {
		#if js
		var endpoint = "http://127.0.0.1:4100";
		#else
		var endpoint = Sys.getEnv("GAMESSA_ENDPOINT") != null ? Sys.getEnv("GAMESSA_ENDPOINT") : "http://127.0.0.1:4100";

		// Самоподписанный dev-стенд (https/wss): отключаем проверку
		// сертификата — это разом действует и на WS (hxWebSockets), и на
		// HTTP (SysHttpClient), т.к. оба сидят на sys.ssl.Socket. JS проверяет
		// сертификат средствами браузера (импортировать в доверенные).
		#if (hl || cpp || neko)
		if (StringTools.startsWith(endpoint, "https"))
			sys.ssl.Socket.DEFAULT_VERIFY_CERT = false;
		#end
		#end

		#if js
		var client = new Client(endpoint);
		client.getAvailableRooms(_ -> start(endpoint), err -> {
			Sys.println('SKIPPED: live server at $endpoint is not reachable (${err.message})');
		});
		#elseif (eval || hl)
		// колбэки HTTP/WS приходят из фоновых потоков; haxe.Timer требует
		// event loop потока — маршалим всё в главный поток с его event loop
		sys.thread.Thread.runWithEventLoop(() -> startMarshaled(endpoint));
		#else
		start(endpoint);
		#end
	}

	#if (eval || hl)
	// eval/hl: очередь + помпинг таймером главного потока
	static var lock:sys.thread.Mutex = new sys.thread.Mutex();
	static var pending:Array<Void->Void> = [];

	static function startMarshaled(endpoint:String):Void {
		Dispatcher.post = f -> {
			lock.acquire();
			pending.push(f);
			lock.release();
		};
		pump();
		probe(endpoint);
	}

	static function pump():Void {
		var batch:Array<Void->Void>;
		lock.acquire();
		batch = pending;
		pending = [];
		lock.release();
		for (fn in batch)
			fn();
		haxe.Timer.delay(pump, 1);
	}

	static function probe(endpoint:String):Void {
		var client = new Client(endpoint);
		var responded = false;
		var reachable = false;

		client.getAvailableRooms(_ -> {
			responded = true;
			reachable = true;
		}, err -> {
			responded = true;
			// любой HTTP-ответ (даже 401) — сервер жив; code 0 — сеть недоступна
			reachable = err.code > 0;
		});

		function check():Void {
			if (!responded) {
				haxe.Timer.delay(check, 50);
				return;
			}

			if (!reachable) {
				Sys.println('SKIPPED: live server at $endpoint is not reachable');
				Sys.exit(0);
			}

			start(endpoint);
		}

		haxe.Timer.delay(check, 50);
	}
	#end

	static function start(endpoint:String):Void {
		var runner = new Runner();
		runner.addCase(new IntegrationTest(endpoint));

		runner.onProgress.add(p -> {
			for (a in p.result.assertations) {
				switch (a) {
					case Success(_):
					case _:
						failedCount++;
				}
			}
		});

		Report.create(runner);
		runner.onComplete.add(_ -> {
			#if (eval || hl)
			// даём репорту допечатать и завершаем event loop
			haxe.Timer.delay(() -> Sys.exit(failedCount == 0 ? 0 : 1), 10);
			#end
		});
		runner.run();
	}
}
