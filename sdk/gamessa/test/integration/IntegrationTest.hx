package;

import gamessa.Client;
import gamessa.MatchMakeError;
import gamessa.Room;
import gamessa.SeatReservation;
import haxe.ds.StringMap;
import utest.Assert;
import utest.Async;

/**
	Полный цикл против живого сервера: регистрация → matchmake → WS-join →
	send/broadcast → request → ping → обрыв → reconnect → leave.
*/
class IntegrationTest extends utest.Test {
	final endpoint:String;

	public function new(endpoint:String) {
		super();
		this.endpoint = endpoint;
	}

	function makeClient():Client {
		var client = new Client(endpoint);
		client.storage = new MapStorage();
		return client;
	}

	function newUser(client:Client, username:String, done:Void->Void):Void {
		client.register(username, "secret123", _ -> done(), err -> Assert.fail('register failed: $err'));
	}

	function joinChat(client:Client, onRoom:Room->Void):Void {
		client.joinOrCreate("chat", {channel: "global"}, reservation -> {
			var room = client.connectRoom(reservation);
			onRoom(room);
		}, err -> Assert.fail('joinOrCreate failed: $err'));
	}

	function testJoinSayAndEcho(async:Async):Void {
		var client = makeClient();
		var username = 'hx_${Std.int(Math.random() * 1000000)}';

		newUser(client, username, () -> {
			joinChat(client, room -> {
				var gotJoin = false;
				var gotEcho = false;

				room.onJoin.add(e -> {
					gotJoin = true;
					Assert.notNull(room.reconnectionToken);
					room.send("say", {text: "gamessa hello"});
				});

				room.onMessage.add(e -> {
					switch (e.type) {
						case "say":
							var m:StringMap<Dynamic> = e.message;
							if (m.get("text") == "gamessa hello") {
								gotEcho = true;
								Assert.equals(room.sessionId, m.get("from"));
							}
						case _:
					}

					if (gotJoin && gotEcho) {
						room.leave();
						async.done();
					}
				});
			});
		});

		async.setTimeout(10000); // s -> Assert.fail("timed out waiting for say echo"), 10);
	}

	function testRequestHistory(async:Async):Void {
		var client = makeClient();

		newUser(client, 'hx_${Std.int(Math.random() * 1000000)}', () -> {
			joinChat(client, room -> {
				room.onJoin.add(e -> {
					room.request("history", {}, res -> {
						var m:StringMap<Dynamic> = res;
						Assert.notNull(m.get("messages"));
						room.leave();
						async.done();
					}, err -> Assert.fail('history failed: $err'));
				});
			});
		});

		async.setTimeout(10000); // s -> Assert.fail("timed out waiting for history"), 10);
	}

	function testPing(async:Async):Void {
		var client = makeClient();

		newUser(client, 'hx_${Std.int(Math.random() * 1000000)}', () -> {
			joinChat(client, room -> {
				room.onJoin.add(e -> {
					room.ping(rtt -> {
						Assert.isTrue(rtt >= 0 && rtt < 5000);
						room.leave();
						async.done();
					}, err -> Assert.fail('ping failed: $err'));
				});
			});
		});

		async.setTimeout(10000); // s -> Assert.fail("timed out waiting for pong"), 10);
	}

	function testDropAndReconnect(async:Async):Void {
		var client = makeClient();

		newUser(client, 'hx_${Std.int(Math.random() * 1000000)}', () -> {
			joinChat(client, room -> {
				var dropped = false;
				var rejoined = false;

				room.onDrop.add(_ -> {
					dropped = true;
				});

				room.onJoin.add(e -> {
					if (!dropped) {
						// первое подключение: рвём транспорт без leave
						haxe.Timer.delay(() -> room.connection.close(), 100);
					} else {
						rejoined = true;
						// session_id сохранён
						Assert.equals(room.sessionId, e.data.get("session_id"));
						room.leave();
						async.done();
					}
				});

				// свой финальный leave тоже приходит в onLeave — валидно
				room.onLeave.add(e -> {
					if (!rejoined)
						Assert.fail('unexpected leave: $e');
				});
			});
		});

		async.setTimeout(15000); // s -> Assert.fail("timed out waiting for reconnect"), 15);
	}

	function testMatchmakeErrors(async:Async):Void {
		var client = makeClient();

		newUser(client, 'hx_${Std.int(Math.random() * 1000000)}', () -> {
			client.joinOrCreate("no_such_room_type", {}, _ -> {
				Assert.fail("expected error");
			}, err -> {
				Assert.equals(520, err.code);
				async.done();
			});
		});

		async.setTimeout(10000); // s -> Assert.fail("timed out"), 10);
	}

	function testLoginMeAndBadCredentials(async:Async):Void {
		var username = 'hx_${Std.int(Math.random() * 1000000)}';
		var client = makeClient();

		// регистрируем пользователя первым клиентом
		newUser(client, username, () -> {
			// логин вторым клиентом: Bearer-токен должен примениться
			var authed = makeClient();
			authed.login(username, "secret123", auth -> {
				Assert.notNull(auth.token);
				Assert.equals(username, auth.user.username);

				// me() с токеном — тот же пользователь
				authed.me(data -> {
					Assert.equals(username, data.user.username);

					// неверный пароль — 401
					var bad = makeClient();
					bad.login(username, "wrong-password", _ -> {
						Assert.fail("expected bad credentials");
					}, err -> {
						Assert.equals(401, err.code);
						async.done();
					});
				}, err -> Assert.fail('me failed: $err'));
			}, err -> Assert.fail('login failed: $err'));
		});

		async.setTimeout(10000);
	}

	function testTokenRestoreFromStorage(async:Async):Void {
		var username = 'hx_${Std.int(Math.random() * 1000000)}';
		var storage = new MapStorage();
		var client = new Client(endpoint, null, storage);

		newUser(client, username, () -> {
			Assert.notNull(client.authToken);

			// новый клиент с тем же storage восстанавливает токен
			var restored = new Client(endpoint, null, storage);
			Assert.isTrue(restored.restoreAuth());
			Assert.equals(client.authToken, restored.authToken);

			// и под восстановленным токеном matchmake работает
			restored.joinOrCreate("chat", {channel: "global"}, reservation -> {
				Assert.notNull(reservation.roomId);
				async.done();
			}, err -> Assert.fail('join with restored token failed: $err'));
		});

		async.setTimeout(10000);
	}

	function testUnauthorizedMatchmakeRejected(async:Async):Void {
		// клиент без токена — сервер обязан ответить 401
		var anonymous = makeClient();
		Assert.isNull(anonymous.authToken);

		anonymous.joinOrCreate("chat", {}, _ -> {
			Assert.fail("expected 401 for anonymous matchmake");
		}, err -> {
			Assert.equals(401, err.code);
			async.done();
		});

		async.setTimeout(10000);
	}
}

/** In-memory storage для тестов (токен живёт в рамках клиента). */
class MapStorage implements gamessa.storage.IStorage {
	var map = new Map<String, String>();

	public function new() {}

	public function getItem(key:String):Null<String> {
		return map.get(key);
	}

	public function setItem(key:String, value:String):Void {
		map.set(key, value);
	}

	public function removeItem(key:String):Void {
		map.remove(key);
	}
}
