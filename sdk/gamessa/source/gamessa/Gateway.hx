package gamessa;

import gamessa.transport.ITransport;
import gamessa.transport.MuxChannel;
import gamessa.transport.TransportClose;
import gamessa.transport.WebSocketTransport;
import gamessa.wire.Frame;
import gamessa.wire.Wire;
import haxe.io.Bytes;

/**
	Общий WebSocket-сокет нескольких комнат — мультиплексирование
	(`GET /ws`, кадры RoomEnter/Mux/MuxClosed; серверная часть —
	`ExGames.Room.Gateway`).

	Создаётся лениво `Client.gateway()` и используется в режиме
	`client.useGateway = true`: `connectRoom` выдаёт каждой комнате
	`MuxChannel` на этом одном соединении (смешанный режим — конкретной
	комнате можно передать dedicated-транспорт в `connectRoom`).

	Обрыв сокета не закрывает комнаты: gateway сам переподключает сокет
	с backoff и повторяет `RoomEnter` в каждую комнату по её актуальному
	reconnection-токену (канал подглядел его в последнем JoinRoom; сервер
	делает reattach и присылает JoinRoom с новым токеном — Room видит
	обычный onJoin). Исчерпание попыток (`maxRetries`) закрывает каналы —
	комнаты уходят в собственный per-room reconnect как fallback.

	Когда каналов не остаётся, соединение закрывается (лениво откроется
	заново при следующем `channelFor`).

	Keepalive — один голый PING на сокет (`keepAliveMs`); пер-комнатные
	PING/PONG (RTT, синхронизация часов) ходят внутри конвертов как обычно.
*/
class Gateway {
	public var client(default, null):Client;

	/** Активный транспорт сокета (тесты/продвинутые сценарии). */
	public var connection(default, null):Null<ITransport>;

	/** Стартовая задержка backoff реконнекта, мс. */
	public var reconnectDelayMs:Int = 100;

	/** Максимум задержки backoff, мс. */
	public var reconnectMaxDelayMs:Int = 5000;

	/** Максимум попыток переподключения сокета (потом каналы закрываются). */
	public var maxRetries:Int = 15;

	/** Интервал keepalive-PING сокета, мс (0 — выключить). */
	public var keepAliveMs:Int = 25_000;

	var channels:Map<String, MuxChannel> = new Map();
	var sendBuffer:Array<Bytes> = [];
	var retry:Int = 0;
	var opening:Bool = false;
	var reconnectTimer:Null<haxe.Timer> = null;

	/** Сокет жив: открыт или находится в цикле реконнекта. */
	var active:Bool = false;

	var disposed:Bool = false;
	var keepAliveTimer:Null<haxe.Timer>;

	/** true — транспорт задан снаружи (тесты): переиспользуем на реконнекте. */
	var injected:Bool = false;

	public function new(client:Client, ?transport:ITransport) {
		this.client = client;
		if (transport != null) {
			injected = true;
			connection = transport;
			wire(connection);
		}
	}

	/** true — сокет открыт (кадры уходят немедленно). */
	public function isConnected():Bool {
		return connection != null && connection.isOpen();
	}

	/**
		Канал комнаты на этом сокете. Соединение открывается лениво:
		`RoomEnter` уйдёт сразу после onOpen.
	*/
	public function channelFor(reservation:SeatReservation):MuxChannel {
		var channel = new MuxChannel(this, reservation.roomId, reservation.sessionId, reservation.reconnectionToken);
		channels.set(reservation.roomId, channel);
		return channel;
	}

	/**
		Канал запросил вход (Room.connect()). Сокет открыт — RoomEnter уходит
		немедленно; закрыт — открываем сокет, вход отправит onOpen (это же
		повторяет вход после реконнекта). Ровно один RoomEnter на цикл
		жизни сокета — иначе сервер отвечает "already entered".
	**/
	@:allow(gamessa.transport.MuxChannel)
	function channelWantsEnter(channel:MuxChannel):Void {
		if (disposed || channel.isDead())
			return;

		if (isConnected()) {
			channel.sendEnter();
		} else if (!opening && reconnectTimer == null) {
			open();
		}
	}

	// ------------------------------------------------------------------
	// Исходящие
	// ------------------------------------------------------------------

	/** Отправка кадра в сокет; на время реконнекта — буфер (cap 256). */
	public function sendFrame(frame:Bytes):Void {
		if (isConnected()) {
			connection.send(frame);
		} else {
			sendBuffer.push(frame);
			if (sendBuffer.length > 256)
				sendBuffer.shift();
		}
	}

	function flushBuffer():Void {
		if (!isConnected())
			return;
		var buffered = sendBuffer;
		sendBuffer = [];
		for (frame in buffered)
			connection.send(frame);
	}

	// ------------------------------------------------------------------
	// Соединение
	// ------------------------------------------------------------------

	function open():Void {
		active = true;
		opening = true;

		var conn:ITransport;
		if (injected) {
			// инжектированный транспорт переиспользуем (контракт тестовых фейков)
			conn = connection;
		} else {
			// WS-транспорт после close не переиспользуется — на каждый
			// (пере)открывающий новый
			conn = new WebSocketTransport(client.gatewayWsUrl(), client.verifyCert);
			connection = conn;
		}

		wire(conn);
		conn.connect();
	}

	function wire(conn:ITransport):Void {
		conn.onOpen = () -> {
			opening = false;
			retry = 0;
			armKeepAlive();

			// вход во все каналы, запросившие его: первичный RoomEnter по
			// брони для новых и reattach по токенам после реконнекта
			for (channel in channels)
				if (channel.isEntered() && !channel.isDead())
					channel.sendEnter();

			flushBuffer();
		};

		conn.onMessage = bytes -> handleFrame(bytes);

		conn.onError = _message -> {
			// транспортный сбой: вслед приедет onClose, обработка там
		};

		conn.onClose = close -> handleClose(close);
	}

	function handleClose(close:TransportClose):Void {
		stopKeepAlive();
		opening = false;

		// закрытие по нашей инициативе (каналов не осталось / dispose)
		if (!active || disposed)
			return;

		var alive = 0;
		for (channel in channels)
			if (!channel.isDead())
				alive++;

		if (alive == 0) {
			reset();
			return;
		}

		reconnectLater();
	}

	function reconnectLater():Void {
		retry++;

		if (retry >= maxRetries) {
			// сдаёмся: каналы закрываются, комнаты уходят в собственный
			// per-room reconnect (fallback на выделенные сокеты)
			var snapshot = [for (channel in channels) channel];
			for (channel in snapshot)
				channel.closedByServer(Wire.CLOSE_RECONNECT_TIMEOUT, "gateway reconnect failed");
			reset();
			return;
		}

		var delay = Std.int(Math.min(reconnectDelayMs * Math.pow(2, retry - 1), reconnectMaxDelayMs));

		reconnectTimer = haxe.Timer.delay(() -> {
			reconnectTimer = null;
			if (!active || disposed)
				return;
			open();
		}, delay);
	}

	/** Полный сброс: сокет закрыт, состояние чистое — откроется заново лениво. */
	function reset():Void {
		active = false;
		opening = false;
		retry = 0;
		stopKeepAlive();

		if (reconnectTimer != null) {
			reconnectTimer.stop();
			reconnectTimer = null;
		}

		var conn = connection;
		connection = null;
		sendBuffer = [];

		try {
			if (conn != null)
				conn.close();
		} catch (e:Dynamic) {}
	}

	/** Окончательно остановить gateway (клиент больше не переиспользуется). */
	public function dispose():Void {
		disposed = true;

		var snapshot = [for (channel in channels) channel];
		for (channel in snapshot)
			channel.closedByServer(Wire.CLOSE_NORMAL, "gateway disposed");

		channels.clear();
		reset();
	}

	// ------------------------------------------------------------------
	// Входящие
	// ------------------------------------------------------------------

	function handleFrame(bytes:Bytes):Void {
		var frame:Frame;
		try {
			frame = Wire.decode(bytes);
		} catch (e:Dynamic) {
			return;
		}

		switch (frame) {
			case Mux(roomId, inner):
				var channel = channels.get(roomId);
				if (channel != null)
					channel.deliver(inner);

			case MuxClosed(roomId, code, message):
				var channel = channels.get(roomId);
				if (channel != null)
					channel.closedByServer(code, message);

			case Ping(_):
				// эхо keepalive-пинга сокета; пер-комнатные PONG — в конвертах

			case _:
		}
	}

	// ------------------------------------------------------------------
	// Каналы
	// ------------------------------------------------------------------

	/** Снятие канала (close/закрыт сервером); последний — закрывает сокет. */
	@:allow(gamessa.transport.MuxChannel)
	function removeChannel(channel:MuxChannel):Void {
		if (channels.get(channel.roomId) == channel)
			channels.remove(channel.roomId);

		var alive = 0;
		for (c in channels)
			if (!c.isDead())
				alive++;

		if (alive == 0)
			reset();
	}

	// ------------------------------------------------------------------
	// Keepalive
	// ------------------------------------------------------------------

	function armKeepAlive():Void {
		stopKeepAlive();
		if (keepAliveMs <= 0)
			return;

		keepAliveTimer = haxe.Timer.delay(() -> {
			if (!active || disposed)
				return;

			if (isConnected()) {
				sendFrame(Wire.encode(Ping(null)));
				armKeepAlive();
			}
			// сокет в реконнекте — onClose уже запустил цикл
		}, keepAliveMs);
	}

	function stopKeepAlive():Void {
		if (keepAliveTimer != null) {
			keepAliveTimer.stop();
			keepAliveTimer = null;
		}
	}
}
