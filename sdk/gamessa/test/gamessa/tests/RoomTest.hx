package gamessa.tests;

import gamessa.Client;
import gamessa.MatchMakeError;
import gamessa.Room;
import gamessa.SeatReservation;
import gamessa.transport.ITransport;
import gamessa.transport.TransportClose;
import gamessa.wire.Frame;
import gamessa.wire.Wire;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import utest.Assert;
import utest.Test;

/**
	Комнатный уровень на loopback-транспорте: reject ожидающего запроса
	кадром RoomError с request_id (сервер поддерживает поле с 2026-09),
	общий onError для прочих ошибок.
*/
class LoopbackTransport implements ITransport {
	public var onOpen:Null<Void->Void>;
	public var onMessage:Null<Bytes->Void>;
	public var onClose:Null<TransportClose->Void>;
	public var onError:Null<String->Void>;

	public var sent:Array<Bytes> = [];

	public function new() {}

	/** Доставляет кадр «от сервера» в присоединённую комнату. */
	public function feed(frame:Frame):Void {
		if (onMessage != null)
			onMessage(Wire.encode(frame));
	}

	public function connect():Void {}

	public function send(data:Bytes):Void
		sent.push(data);

	public function close():Void {}

	public function isOpen():Bool
		return true;
}


class RoomTest extends utest.Test {
	function makeJoinedRoom():{room:Room, transport:LoopbackTransport} {
		var client = new Client("http://127.0.0.1:4000");
		var transport = new LoopbackTransport();
		var room = new Room(client, new SeatReservation("room1", "s1"), transport);
		var hello:StringMap<Dynamic> = new StringMap();
		hello.set("session_id", "s1");
		hello.set("room_id", "room1");
		hello.set("reconnection_token", "tok");
		transport.feed(JoinRoom(hello));
		return {room: room, transport: transport};
	}

	function testErrorFrameWithRequestIdRejectsPendingImmediately() {
		var t = makeJoinedRoom();
		var rejected:Null<MatchMakeError> = null;
		var resolved = false;

		t.room.request("whoami", {}, 60_000, _ -> resolved = true, err -> rejected = err);
		// request_id = 1 (первый запрос комнаты)
		t.transport.feed(RoomError(526, "boom", 1));

		Assert.notNull(rejected);
		Assert.equals(526, rejected.code);
		Assert.equals("boom", rejected.message);
		Assert.isFalse(resolved);


	}

	function testErrorFrameWithoutRequestIdGoesToOnError() {
		var t = makeJoinedRoom();
		var errorEvent:{code:Int, message:String, requestId:Null<Int>} = null;
		var rejected:Null<MatchMakeError> = null;

		t.room.onError.add(e -> errorEvent = e);
		t.room.request("whoami", {}, 60_000, _ -> {}, err -> rejected = err);

		t.transport.feed(RoomError(4002, "kicked"));

		// запрос остаётся pending (отклонится по таймауту/при закрытии),
		// ошибка уходит в общий onError
		Assert.isNull(rejected);
		Assert.notNull(errorEvent);
		Assert.equals(4002, errorEvent.code);
		Assert.equals("kicked", errorEvent.message);
		Assert.equals(null, errorEvent.requestId);


	}

	function testErrorFrameWithUnknownRequestIdGoesToOnError() {
		var t = makeJoinedRoom();
		var errorEvent:{code:Int, message:String, requestId:Null<Int>} = null;
		var rejected:Null<MatchMakeError> = null;

		t.room.onError.add(e -> errorEvent = e);
		t.room.request("whoami", {}, 60_000, _ -> {}, err -> rejected = err);

		// чужой/поздний request_id — не наш pending
		t.transport.feed(RoomError(526, "late", 999));

		Assert.isNull(rejected);
		Assert.notNull(errorEvent);
		Assert.equals(526, errorEvent.code);
		Assert.equals(999, errorEvent.requestId);


	}
}
