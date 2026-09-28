package gamessa;

import gamessa.transport.ITransport;
import gamessa.transport.TransportClose;
import gamessa.transport.WebSocketTransport;
import gamessa.util.Signal;
import gamessa.wire.Frame;
import gamessa.wire.Wire;
import haxe.ds.StringMap;
import haxe.io.Bytes;

typedef JoinEvent = {
	var data:StringMap<Dynamic>;
}

	typedef ErrorEvent = {
		var code:Int;
		var message:String;
		/** request_id отклонённого запроса (null — ошибка не про запрос). */
		var requestId:Null<Int>;
	}

typedef LeaveEvent = {
	var code:Int;
	var reason:String;
}

typedef RequestCallback = {
	var resolve:Dynamic->Void;
	var reject:MatchMakeError->Void;
	var timer:Null<haxe.Timer>;
}

/**
	Игровой WS-канал комнаты. Создаётся через `Client.connectRoom` —
	сам открывает транспорт, обрабатывает рукопожатие и reconnect.

	Сигналы:

	* `onJoin` — кадр JoinRoom (room_id, session_id, reconnection_token);
	* `onMessage` — RoomData(type, payload);
	* `onStateChange` — RoomState (полный снапшот);
	* `onError` — кадр RoomError;
	* `onDrop` — не-согласованный обрыв: начат auto-reconnect (backoff);
	* `onLeave` — комната покинута (согласованно или после исчерпания попыток).

	`send` до JOIN буферизуется (flush после рукопожатия); при обрыве —
	буферизуется до reconnect (cap `bufferLimit`).
*/
class Room<S> {
	public var client(default, null):Client;
	public var reservation(default, null):SeatReservation;
	public var roomId(get, null):String;
	public var sessionId(get, null):String;
	public var reconnectionToken(get, null):Null<String>;

	// ------------------------------------------------------------------
	// События
	// ------------------------------------------------------------------

	public var onJoin(default, null):Signal<JoinEvent> = new Signal();
	public var onMessage(default, null):Signal<{type:Dynamic, message:Dynamic}> = new Signal();
	public var onStateChange(default, null):Signal<S> = new Signal();
	public var onError(default, null):Signal<ErrorEvent> = new Signal();
	/** Не-согласованный обрыв: начат auto-reconnect (payload — null). */
	public var onDrop(default, null):Signal<Dynamic> = new Signal();
	public var onLeave(default, null):Signal<LeaveEvent> = new Signal();

	// ------------------------------------------------------------------
	// Reconnect-настройки
	// ------------------------------------------------------------------

	/** Стартовая задержка backoff, мс. */
	public var reconnectDelayMs:Int = 100;

	/** Максимум задержки backoff, мс. */
	public var reconnectMaxDelayMs:Int = 5000;

	/** Максимум попыток переподключения. */
	public var maxRetries:Int = 15;

	/** Лимит буфера исходящих при обрыве. */
	public var bufferLimit:Int = 10;

	/** Таймаут request/1 по умолчанию, мс. */
	public var requestTimeoutMs:Int = 10_000;

	/**
		Интервал keepalive-PING, мс (0 — выключить). Сервер закрывает WS без
		данных от клиента (WebSockAdapter `timeout: 60_000` в WsController),
		поэтому SDK по умолчанию шлёт PING каждые 25с — таймер сбрасывается и
		соединение не рвётся во время простоя. Держите меньше серверного
		таймаута и таймаутов NAT/прокси.
	*/
	public var keepAliveMs:Int = 25_000;

	// ------------------------------------------------------------------
	// Внутреннее
	// ------------------------------------------------------------------

	/** Активный транспорт (для продвинутых сценариев и тестов). */
	public var connection(default, null):ITransport;

	var joined:Bool = false;
	var leaving:Bool = false;
	var disposed:Bool = false;

	var sendBuffer:Array<Bytes> = [];
	var pending:Map<Int, RequestCallback> = new Map();
	var nextRequestId:Int = 1;

	var retry:Int = 0;
	var pingSentAt:Float = 0;

	/** Смещение часов (unix-ms): серверное минус локальное, EMA по PONG-замерам. */
	var serverOffset:Null<Float> = null;

	/** Последний измеренный RTT (ms) — уходит серверу с ping-payload. */
	var lastRtt:Null<Int> = null;

	/** Последний снапшот состояния (после onStateChange). Анонимное дерево,
		типизированное параметром `S` (typedef от wire-структуры комнаты);
		динамические ключи (sid → значение) — `Dynamic`. */
	public var state(default, null):Null<S>;

	public function new(client:Client, reservation:SeatReservation, ?transport:ITransport) {
		this.client = client;
		this.reservation = reservation;
		this.connection = transport != null
			? transport
			: new WebSocketTransport(client.roomWsUrl(reservation.roomId, reservation.sessionId), client.verifyCert);
		attach();
	}

	function get_roomId():String {
		return reservation.roomId;
	}

	function get_sessionId():String {
		return reservation.sessionId;
	}

	function get_reconnectionToken():Null<String> {
		return reservation.reconnectionToken;
	}

	// ------------------------------------------------------------------
	// Исходящие
	// ------------------------------------------------------------------

	/** Игровое сообщение: broadcast-модель (fire-and-forget). */
	public function send(type:Dynamic, payload:Dynamic):Void {
		queueOrSend(Wire.encode(RoomData(type, payload)));
	}

	/**
		Запрос-ответ: сервер отвечает RoomResponse с тем же request_id.
		Ошибка обработки приходит кадром RoomError с этим request_id —
		колбэк onError вызывается сразу (серверы без поддержки request_id
		в ошибках — fallback по таймауту).
	*/
	public function request(type:Dynamic, payload:Dynamic, ?timeoutMs:Int, onResult:Dynamic->Void, onError:MatchMakeError->Void):Void {
		var requestId = nextRequestId++;

		var cb:RequestCallback = {
			resolve: onResult,
			reject: onError,
			timer: null
		};

		cb.timer = haxe.Timer.delay(() -> {
			if (pending.remove(requestId))
				onError(new MatchMakeError(Wire.ERR_INTERNAL, 'request "$type" timed out'));
		}, timeoutMs != null ? timeoutMs : requestTimeoutMs);

		pending.set(requestId, cb);
		queueOrSend(Wire.encode(RoomRequest(requestId, type, payload)));
	}

	/**
		RTT-замер: отправляет PING и измеряет время до PONG. Попутно
		обновляет оценку серверного времени (`serverNow`).
	*/
	public function ping(onResult:Float->Void, onError:String->Void):Void {
		var handler:Float->Void = null;
		var done = false;
		handler = rtt -> {
			done = true;
			pingHandlers.remove(handler);
			onResult(rtt);
		};
		pingHandlers.push(handler);

		haxe.Timer.delay(() -> {
			if (!done) {
				pingHandlers.remove(handler);
				onError("ping timed out");
			}
		}, requestTimeoutMs);

		var t0 = now();
		pingSentAt = t0;
		queueOrSend(Wire.encode(Ping(timePayload(t0))));
	}

	/**
		Оценка серверного времени (unix-миллисекунды): локальные монотонные
		часы + смещение, оценённое по PONG-замерам (EMA; точность порядка
		половины RTT). До первого PONG с меткой смещение неизвестно —
		возвращаются локальные часы; после join синхронизация уходит сразу,
		далее обновляется на каждом keepalive-PING (раз в `keepAliveMs`).
		Годится для серверных дедлайнов/таймингов, передаваемых как unix-ms.
	*/
	public function serverNow():Float {
		return now() + (serverOffset == null ? 0.0 : serverOffset);
	}

	/** true, когда оценка серверного времени подтверждена хотя бы одним PONG. */
	public function timeSynced():Bool {
		return serverOffset != null;
	}

	/**
		Покидает комнату. При `consented = true` отправляет LeaveRoom и не
		делает reconnect; иначе — то же самое (принудительный локальный выход).
	*/
	public function leave(consented:Bool = true):Void {
		if (leaving)
			return;
		leaving = true;

		if (connection.isOpen())
			queueOrSend(Wire.encode(LeaveRoom));

		dispose();
		onLeave.dispatch({code: Wire.CLOSE_NORMAL, reason: "client left"});
	}

	// ------------------------------------------------------------------
	// Транспорт
	// ------------------------------------------------------------------

	function attach():Void {
		connection.onOpen = () -> {};
		connection.onMessage = bytes -> handleFrame(bytes);
		connection.onError = message -> onError.dispatch({code: 0, message: message, requestId: null});
		connection.onClose = close -> handleClose(close);

		connection.connect();
	}

	function handleFrame(bytes:Bytes):Void {
		var frame:Frame;
		try {
			frame = Wire.decode(bytes);
		} catch (e:Dynamic) {
			onError.dispatch({code: Wire.ERR_INTERNAL, message: 'invalid frame: $e', requestId: null});
			return;
		}

		switch (frame) {
			case JoinRoom(data):
				joined = true;
				retry = 0;
				reservation.sessionId = data.get("session_id");
				reservation.reconnectionToken = data.get("reconnection_token");
				// сначала обработчики (их send-ы встанут в буфер, если что-то
				// не так), затем flush — накопленное до join уходит серверу
				onJoin.dispatch({data: data});
				flushBuffer();
				armKeepAlive();
				syncTime();

			case RoomData(type, payload):
				onMessage.dispatch({type: type, message: payload});

			case RoomState(payload):
				// снапшот конвертируется в анонимные объекты (StatePatch.toAnon) —
				// только у них прямые поля работают на всех таргетах; тип S
				// задаёт вызывающий (Room<S>)
				state = cast StatePatch.toAnon(payload);
				onStateChange.dispatch(state);

			case RoomStatePatch(payload):
				// дельта: применяем операции к анонимному дереву состояния;
				// onStateChange срабатывает на каждый патч (как в Colyseus)
				state = cast StatePatch.applyAnon(state, payload);
				onStateChange.dispatch(state);

			case RoomError(code, message, requestId):
				// ошибка про конкретный запрос — отклоняем только его;
				// если pending уже нет (таймаут/не наш кадр) — общий onError
				if (requestId != null && pending.exists(requestId)) {
					rejectPending(requestId, new MatchMakeError(code, message));
				} else {
					onError.dispatch({code: code, message: message, requestId: requestId});
				}

			case Ping(payload):
				// ответ сервера на наш PING: резолвим RTT-замеры; с payload —
				// обновляем смещение часов (метка эхируется, сервер добавляет
				// свой unix-ms штамп; середина RTT — момент серверной обработки).
				// Dynamic-значения достаются в типизированные локалы: `cast` на HL
				// калечит Float > 2^31 (int32-насыщение)
				var t1 = now();
				var t0:Float = pingSentAt;

				if (payload != null) {
					var echoed:Null<Float> = payload.get("t");
					if (echoed != null)
						t0 = echoed;

					var stamped:Null<Float> = payload.get("ts");
					if (stamped != null) {
						var sample:Float = stamped - (t0 + t1) / 2;
						serverOffset = serverOffset == null ? sample : serverOffset + (sample - serverOffset) * 0.25;
					}
				}

				var rtt = t1 - t0;
				lastRtt = rtt < 0 ? 0 : Std.int(rtt);
				var handlers = pingHandlers;
				pingHandlers = [];
				for (handler in handlers)
					handler(rtt);

			case RoomResponse(requestId, payload):
				var cb = pending.get(requestId);
				if (cb != null) {
					pending.remove(requestId);
					if (cb.timer != null)
						cb.timer.stop();
					cb.resolve(payload);
				}

			case RoomRequest(_, _, _):
				// сервер не шлёт запросы клиенту — игнорируем

			case LeaveRoom:
				// сервер подтверждает выход — закрытие придёт отдельно
		}
	}

	function handleClose(close:TransportClose):Void {
		if (leaving || disposed) {
			dispose();
			return;
		}

		// не-согласованный обрыв: попытки reconnect по токену
		joined = false;
		stopKeepAlive();
		onDrop.dispatch(null);

		if (reservation.reconnectionToken == null) {
			// reconnect недоступен — выходим с кодом таймаута
			dispose();
			onLeave.dispatch({code: Wire.CLOSE_RECONNECT_TIMEOUT, reason: "no reconnection token"});
			return;
		}

		scheduleReconnect();
	}

	/** Отклоняет ожидающий запрос (снимая его таймаут-колбэк). */
	function rejectPending(requestId:Int, err:MatchMakeError):Void {
		var cb = pending.get(requestId);
		if (cb != null) {
			pending.remove(requestId);
			if (cb.timer != null)
				cb.timer.stop();
			cb.reject(err);
		}
	}

	function scheduleReconnect():Void {
		if (disposed)
			return;

		var delay = Std.int(Math.min(reconnectDelayMs * Math.pow(2, retry), reconnectMaxDelayMs));

		haxe.Timer.delay(() -> {
			if (disposed || leaving)
				return;

			client.reconnect(roomId, reservation.reconnectionToken, reservation.sessionId,
				res -> {
					if (disposed || leaving)
						return;
					openReconnectTransport(res);
				},
				err -> {
					// окончательный отказ (комната/токен не существуют) —
					// ретраи бессмысленны, завершаем сразу
					if (isPermanentReconnectError(err)) {
						dispose();
						onLeave.dispatch({code: Wire.CLOSE_RECONNECT_TIMEOUT, reason: 'reconnect rejected: ${err.message}'});
						return;
					}

					retry++;
					if (retry >= maxRetries) {
						dispose();
						onLeave.dispatch({code: Wire.CLOSE_RECONNECT_TIMEOUT, reason: 'reconnect failed: ${err.message}'});
					} else {
						scheduleReconnect();
					}
				});
		}, delay);
	}

	/** Отказ сервера, при котором повторять reconnect бессмысленно. */
	static function isPermanentReconnectError(err:MatchMakeError):Bool {
		return err.code == Wire.ERR_UNKNOWN_ROOM_TYPE
			|| err.code == Wire.ERR_NO_ROOM
			|| err.code == Wire.ERR_UNKNOWN_ROOM;
	}

	function openReconnectTransport(res:SeatReservation):Void {
		connection = new WebSocketTransport(client.roomWsUrl(roomId, res.sessionId, res.reconnectionToken), client.verifyCert);
		attach();
	}

	function queueOrSend(frame:Bytes):Void {
		if (joined && connection.isOpen()) {
			connection.send(frame);
		} else {
			sendBuffer.push(frame);
			if (sendBuffer.length > bufferLimit)
				sendBuffer.shift();
		}
	}

	function flushBuffer():Void {
		if (!joined)
			return;
		var buffered = sendBuffer;
		sendBuffer = [];
		for (frame in buffered)
			connection.send(frame);
	}

	// ------------------------------------------------------------------
	// Внутреннее
	// ------------------------------------------------------------------

	var pingHandlers:Array<Float->Void> = [];
	var keepAliveTimer:Null<haxe.Timer>;

	/**
		Keepalive: раз в keepAliveMs шлёт PING, сбрасывая таймер неактивности
		сервера (и NAT/прокси). Пока ждётся ответ ручного ping(), не мешаем.
		Таймер живёт в потоке, обработавшем JoinRoom (главном при marshaling).
	*/
	function armKeepAlive():Void {
		stopKeepAlive();
		if (keepAliveMs <= 0)
			return;

		keepAliveTimer = haxe.Timer.delay(() -> {
			if (!joined || disposed || leaving)
				return;

			if (connection.isOpen()) {
				if (pingHandlers.length == 0)
					queueOrSend(Wire.encode(Ping(timePayload(now()))));
				armKeepAlive();
			}
			// если isOpen() == false, handleClose вот-вот запустит reconnect
		}, keepAliveMs);
	}

	/** Первичная синхронизация серверного времени — сразу после join. */
	function syncTime():Void {
		if (pingHandlers.length == 0)
			queueOrSend(Wire.encode(Ping(timePayload(now()))));
	}

	function timePayload(t0:Float):StringMap<Dynamic> {
		var m = new StringMap<Dynamic>();
		m.set("t", t0);
		// клиент-отчётный RTT: сервер хранит для мониторинга/лаг-логики
		// (целое: сервер валидирует is_integer)
		if (lastRtt != null)
			m.set("rtt", lastRtt);
		return m;
	}

	function stopKeepAlive():Void {
		if (keepAliveTimer != null) {
			keepAliveTimer.stop();
			keepAliveTimer = null;
		}
	}

	function dispose():Void {
		disposed = true;
		joined = false;
		stopKeepAlive();
		sendBuffer = [];

		for (cb in pending) {
			if (cb.timer != null)
				cb.timer.stop();
			cb.reject(new MatchMakeError(Wire.CLOSE_NORMAL, "room closed"));
		}
		pending.clear();

		try {
			connection.close();
		} catch (e:Dynamic) {}
	}

	static function now():Float {
		return haxe.Timer.stamp() * 1000.0;
	}
}
