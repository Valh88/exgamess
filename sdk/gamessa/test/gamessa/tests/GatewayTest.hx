package gamessa.tests;

import gamessa.Client;
import gamessa.Gateway;
import gamessa.SeatReservation;
import gamessa.transport.ITransport;
import gamessa.transport.MuxChannel;
import gamessa.transport.TransportClose;
import gamessa.wire.Frame;
import gamessa.wire.Wire;
import haxe.ds.StringMap;
import haxe.io.Bytes;
import utest.Assert;

/**
	Мультиплексирование: gateway + каналы поверх фейкового транспорта сокета
	(механика Room поверх канала покрыта RoomTest — транспортный контракт
	тот же ITransport).
*/
class GatewayTest extends utest.Test {
	/**
		Фейковый транспорт сокета: connect() открывает сразу (и повторно после
		close — reconnect gateway переиспользует транспорт), feed() кормит
		gateway кадрами «сервера».
	*/
	var client:Client;

	public function new() {
		super();
		client = new Client("http://localhost:9");
	}

	function makeGateway(socket:FakeSocket):Gateway {
		return new Gateway(client, socket);
	}

	function reservation(roomId:String, sessionId:String):SeatReservation {
		return new SeatReservation(roomId, sessionId);
	}

	function joinFrame(sessionId:String, token:String):Bytes {
		var data = new StringMap<Dynamic>();
		data.set("room_id", "r1");
		data.set("session_id", sessionId);
		data.set("reconnection_token", token);
		return Wire.encode(JoinRoom(data));
	}

	function testChannelForEntersRoomOnOpen() {
		var socket = new FakeSocket();
		var gateway = makeGateway(socket);

		var channel = gateway.channelFor(reservation("r1", "s1"));
		channel.connect();

		// сокет открылся лениво, RoomEnter ушёл по брони (без токена)
		Assert.equals(1, socket.connectCalls);

		var enters = socket.sentFrames().filter(f -> return matchRoomEnter(f));
		Assert.equals(1, enters.length);

		switch (enters[0]) {
			case RoomEnter(data):
				Assert.equals("r1", data.get("room_id"));
				Assert.equals("s1", data.get("session_id"));
				Assert.equals(null, data.get("reconnection_token"));
			case _:
				Assert.fail("expected RoomEnter");
		}

		Assert.isTrue(channel.isOpen());
	}

	function testDeliverRoutesByRoomIdAndTracksToken() {
		var socket = new FakeSocket();
		var gateway = makeGateway(socket);

		var got1:Array<Bytes> = [];
		var got2:Array<Bytes> = [];
		var channel1 = gateway.channelFor(reservation("r1", "s1"));
		var channel2 = gateway.channelFor(reservation("r2", "s2"));
		channel1.connect();
		channel2.connect();
		channel1.onMessage = bytes -> got1.push(bytes);
		channel2.onMessage = bytes -> got2.push(bytes);

		// кадр комнаты r2 приходит только в её канал
		socket.feed(Mux("r2", Wire.encode(RoomData("say", mapOf("text", "привет")))));

		Assert.equals(0, got1.length);
		Assert.equals(1, got2.length);

		// JoinRoom в конверте обновляет сессию/токен канала (для re-enter)
		socket.feed(Mux("r1", joinFrame("s1-new", "tok-rotated")));

		Assert.equals(1, got1.length);
		Assert.equals("s1-new", channel1.sessionId);
		Assert.equals("tok-rotated", channel1.reconnectionToken);
	}

	function testMuxClosedClosesOnlyItsChannel() {
		var socket = new FakeSocket();
		var gateway = makeGateway(socket);

		var closed:Null<TransportClose> = null;
		var channel1 = gateway.channelFor(reservation("r1", "s1"));
		var channel2 = gateway.channelFor(reservation("r2", "s2"));
		channel1.connect();
		channel2.connect();
		channel1.onClose = close -> closed = close;

		socket.feed(MuxClosed("r1", 4000, "client left"));

		Assert.equals(4000, closed.code);
		Assert.equals("client left", closed.reason);
		Assert.isFalse(channel1.isOpen());
		Assert.isTrue(channel2.isOpen());
		// сокет жив: второй канал продолжает работать
		Assert.isTrue(gateway.isConnected());
	}

	function testChannelCloseSendsWrappedLeaveRoom() {
		var socket = new FakeSocket();
		var gateway = makeGateway(socket);
		var channel = gateway.channelFor(reservation("r1", "s1"));
		channel.connect();

		channel.close();

		// исходящие: RoomEnter, затем Mux(r1, LeaveRoom)
		var frames = socket.sentFrames();
		Assert.equals(2, frames.length);

		switch (frames[1]) {
			case Mux(roomId, inner):
				Assert.equals("r1", roomId);
				Assert.equals("0c", inner.toHex());
			case _:
				Assert.fail("expected Mux(LeaveRoom)");
		}

		Assert.isFalse(channel.isOpen());
	}

	function testGatewayDropReentersWithRotatedToken(async:utest.Async) {
		var socket = new FakeSocket();
		var gateway = makeGateway(socket);
		gateway.reconnectDelayMs = 10;
		gateway.reconnectMaxDelayMs = 10;

		var channel1 = gateway.channelFor(reservation("r1", "s1"));
		var channel2 = gateway.channelFor(reservation("r2", "s2"));
		channel1.connect();
		channel2.connect();

		// сервер ротировал токены после join (каналы их подглядели)
		socket.feed(Mux("r1", joinFrame("s1", "tok1")));
		socket.feed(Mux("r2", joinFrame("s2", "tok2")));

		socket.sent = [];
		socket.drop();

		haxe.Timer.delay(() -> {
			// сокет переподключился и повторил RoomEnter в обе комнаты —
			// уже с актуальными токенами (reattach на сервере)
			Assert.equals(2, socket.connectCalls);

			var reenters = socket.sentFrames().filter(f -> return matchRoomEnter(f));
			Assert.equals(2, reenters.length);

			var tokens = new Map<String, String>();
			for (f in reenters) {
				switch (f) {
					case RoomEnter(data):
						tokens.set(data.get("room_id"), data.get("reconnection_token"));
					case _:
				}
			}

			Assert.equals("tok1", tokens.get("r1"));
			Assert.equals("tok2", tokens.get("r2"));
			async.done();
		}, 200);
	}

	function testExhaustedRetriesCloseChannels() {
		var socket = new FakeSocket();
		var gateway = makeGateway(socket);
		gateway.maxRetries = 1;

		var closes:Array<TransportClose> = [];
		var channel = gateway.channelFor(reservation("r1", "s1"));
		channel.connect();
		channel.onClose = close -> closes.push(close);

		socket.drop();

		// единственная попытка исчерпана сразу: канал закрыт кодом 4003,
		// комнаты (в реальном использовании) уходят в per-room reconnect
		Assert.equals(1, closes.length);
		Assert.equals(Wire.CLOSE_RECONNECT_TIMEOUT, closes[0].code);
		Assert.isFalse(gateway.isConnected());
	}

	function testLastChannelCloseClosesSocket() {
		var socket = new FakeSocket();
		var gateway = makeGateway(socket);
		var channel = gateway.channelFor(reservation("r1", "s1"));
		channel.connect();

		Assert.isTrue(gateway.isConnected());

		channel.close();

		// каналов не осталось — сокет закрывается (лениво откроется заново)
		Assert.isFalse(gateway.isConnected());
		Assert.isFalse(socket.isOpen());
	}

	function testSocketDropAndRestoreSignals(async:utest.Async) {
		var socket = new FakeSocket();
		var gateway = makeGateway(socket);
		gateway.reconnectDelayMs = 10;
		gateway.reconnectMaxDelayMs = 10;

		var drops = 0;
		var restores = 0;
		gateway.onSocketDrop.add(_ -> drops++);
		gateway.onSocketRestore.add(_ -> restores++);

		var channel = gateway.channelFor(reservation("r1", "s1"));
		channel.connect();

		socket.drop();
		Assert.equals(1, drops);

		// сокет переподключился: сигнал восстановления, ровно один
		haxe.Timer.delay(() -> {
			Assert.equals(1, restores);
			Assert.equals(1, drops);
			Assert.isTrue(gateway.isConnected());
			async.done();
		}, 200);
	}

	function testSocketRttFromKeepaliveEcho() {
		var socket = new FakeSocket();
		var gateway = makeGateway(socket);
		var channel = gateway.channelFor(reservation("r1", "s1"));
		channel.connect();

		Assert.isFalse(gateway.socketRtt != null);

		// эхо keepalive-ping'а с нашей меткой t
		var t0 = haxe.Timer.stamp() * 1000.0 - 5;
		var payload = new StringMap<Dynamic>();
		payload.set("t", t0);
		socket.feed(Ping(payload));

		Assert.isTrue(gateway.socketRtt != null);
		Assert.isTrue(gateway.socketRtt >= 4); // ~5ms «полёта»
	}

	static function matchRoomEnter(f:Frame):Bool {
		return switch (f) {
			case RoomEnter(_): true;
			case _: false;
		};
	}

	static function mapOf(k1:String, v1:Dynamic):StringMap<Dynamic> {
		var m = new StringMap<Dynamic>();
		m.set(k1, v1);
		return m;
	}
}

	private class FakeSocket implements ITransport {
		public var onOpen:Null<Void->Void>;
		public var onMessage:Null<Bytes->Void>;
		public var onClose:Null<TransportClose->Void>;
		public var onError:Null<String->Void>;

		public var sent:Array<Bytes> = [];
		public var connectCalls:Int = 0;
		public var closeNotified:Bool = false;

		var open:Bool = false;

		public function new() {}

		public function connect():Void {
			connectCalls++;
			open = true;
			if (onOpen != null)
				onOpen();
		}

		public function send(data:Bytes):Void {
			sent.push(data);
		}

		public function close():Void {
			open = false;
			notifyClose(1000, "fake closed");
		}

		public function isOpen():Bool {
			return open;
		}

		/** Обрыв сокета «из сети» (без нашего close()). */
		public function drop():Void {
			open = false;
			notifyClose(1006, "dropped");
		}

		function notifyClose(code:Int, reason:String):Void {
			if (closeNotified)
				return;
			closeNotified = true;
			if (onClose != null)
				onClose(new TransportClose(code, reason));
		}

		/** Кадр «сервера» в сокет gateway. */
		public function feed(frame:Frame):Void {
			if (onMessage != null)
				onMessage(Wire.encode(frame));
		}

		/** Последние исходящие кадры заданного вида. */
		public function sentFrames():Array<Frame> {
			var out:Array<Frame> = [];
			for (bytes in sent) {
				try {
					out.push(Wire.decode(bytes));
				} catch (e:Dynamic) {}
			}
			return out;
		}
	}

