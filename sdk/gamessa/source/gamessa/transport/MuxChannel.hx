package gamessa.transport;

import gamessa.Gateway;
import gamessa.wire.Frame;
import gamessa.wire.Wire;
import haxe.ds.StringMap;
import haxe.io.Bytes;

/**
	Транспорт комнаты на общем сокете `Gateway` (`ITransport` для `Room`):
	исходящие кадры заворачиваются в `Mux{r, f}`, входящие приходят
	распакованными из конверта.

	Канал подглядывает `JoinRoom` в проходящих кадрах и обновляет свои
	`sessionId`/`reconnectionToken` — gateway использует их для повторного
	`RoomEnter` после реконнекта сокета (токен сервер ротирует на каждом
	reattach, актуальный именно последний).

	Закрытие:

	* `close()` — согласованный уход: wrapнутый `LeaveRoom` и локальный
	  teardown; `mux_closed` от сервера после этого игнорируется;
	* `closedByServer()` — `mux_closed` (кик, комната распалась, отказ
	  входа): канал умирает, Room получает onClose и действует по своей
	  логике обрыва.

	Пока сокет реконнектится, `isOpen()` = false — Room буферизует исходящие
	своим обычным механизмом (`bufferLimit`) и flush'ит их после повторного
	JoinRoom.
*/
class MuxChannel implements ITransport {
	public var gateway(default, null):Gateway;
	public var roomId(default, null):String;

	/** Актуальная сессия (обновляется по JoinRoom). */
	public var sessionId(default, null):String;

	/** Актуальный токен переподключения (ротируется сервером на reattach). */
	public var reconnectionToken(default, null):Null<String>;

	public var onOpen:Null<Void->Void>;
	public var onMessage:Null<Bytes->Void>;
	public var onClose:Null<TransportClose->Void>;
	public var onError:Null<String->Void>;

	var closedLocally:Bool = false;
	var closedByGateway:Bool = false;
	var entered:Bool = false;

	public function new(gateway:Gateway, roomId:String, sessionId:String, ?reconnectionToken:String) {
		this.gateway = gateway;
		this.roomId = roomId;
		this.sessionId = sessionId;
		this.reconnectionToken = reconnectionToken;
	}

	public function connect():Void {
		// факт намерения войти: сам RoomEnter шлёт gateway — ровно один раз
		// на цикл жизни сокета (сразу при открытом, из onOpen при закрытом
		// и после реконнекта)
		entered = true;
		gateway.channelWantsEnter(this);
	}

	/** true — канал запрашивал вход (gateway входит им в каждый open-цикл). */
	public function isEntered():Bool {
		return entered;
	}

	/** Кадр RoomEnter с актуальными sessionId/токеном; зовёт только Gateway. */
	public function sendEnter():Void {
		gateway.sendFrame(Wire.encode(RoomEnter(enterPayload())));
	}

	public function send(data:Bytes):Void {
		gateway.sendFrame(Wire.encode(Mux(roomId, data)));
	}

	public function close():Void {
		if (closedLocally)
			return;
		closedLocally = true;

		// согласованный выход; mux_closed (4000 "client left") придёт позже —
		// канал уже снят, gateway его проигнорирует
		if (gateway.isConnected())
			gateway.sendFrame(Wire.encode(Mux(roomId, Wire.encode(LeaveRoom))));

		gateway.removeChannel(this);
	}

	public function isOpen():Bool {
		return !closedLocally && !closedByGateway && gateway.isConnected();
	}

	/** true — канал закрыт (локально или сервером), повторный вход не нужен. */
	public function isDead():Bool {
		return closedLocally || closedByGateway;
	}

	// gateway → комната: кадр уже распакован из конверта
	public function deliver(frame:Bytes):Void {
		parseJoin(frame);
		if (onMessage != null)
			onMessage(frame);
	}

	/** mux_closed от сервера: канал закрывается окончательно. */
	public function closedByServer(code:Int, message:String):Void {
		if (isDead())
			return;
		closedByGateway = true;
		gateway.removeChannel(this);

		// причину — в onError Room (код/сообщение отказа входа или кика),
		// затем onClose запускает обычную логику обрыва Room
		if (onError != null)
			onError(message);
		if (onClose != null)
			onClose(new TransportClose(code, message));
	}

	/** Отправляет RoomEnter с актуальными sessionId/токеном (вход и re-enter). */
	function enterPayload():StringMap<Dynamic> {
		var m = new StringMap<Dynamic>();
		m.set("room_id", roomId);
		m.set("session_id", sessionId);
		if (reconnectionToken != null)
			m.set("reconnection_token", reconnectionToken);
		return m;
	}

	function parseJoin(frame:Bytes):Void {
		// декод здесь не должен падать (кадр пришёл от сервера), но Room
		// получит кадр со своим try/catch — здесь молча пропускаем
		try {
			switch (Wire.decode(frame)) {
				case JoinRoom(data):
					var sid = data.get("session_id");
					if (sid != null)
						sessionId = sid;
					var token = data.get("reconnection_token");
					if (token != null)
						reconnectionToken = token;
				case _:
			}
		} catch (e:Dynamic) {}
	}
}
