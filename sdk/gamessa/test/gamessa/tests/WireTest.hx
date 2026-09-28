package gamessa.tests;

import haxe.io.Bytes;
import haxe.ds.StringMap;
import gamessa.wire.Frame;
import gamessa.wire.Wire;
import gamessa.wire.WireError;
import utest.Assert;

/**
	Векторные тесты по кадрам, закодированным сервером (`ExGames.Wire`),
	и roundtrip кодирования.
*/
class WireTest extends utest.Test {
	static function hex2bytes(hex:String): Bytes {
		var out = Bytes.alloc(Std.int(hex.length / 2));
		for (i in 0...out.length)
			out.set(i, Std.parseInt('0x' + hex.substr(i * 2, 2)));
		return out;
	}

	function testGoldenJoinFrame() {
		var frame = Wire.decode(hex2bytes(
			"0a83aa73657373696f6e5f6964ac734b6438336a64446b326d31a7726f6f6d5f6964a941623378597a394b70b27265636f6e6e656374696f6e5f746f6b656ed923746f6b3132333435363738393031323334353637383930313233343536373839303132"
		));

		switch (frame) {
			case JoinRoom(data):
				Assert.equals("sKd83jdDk2m1", data.get("session_id"));
				Assert.equals("Ab3xYz9Kp", data.get("room_id"));
				Assert.equals("tok12345678901234567890123456789012", data.get("reconnection_token"));
			case _:
				Assert.fail("expected JoinRoom");
		}

		Assert.equals(Wire.OP_JOIN_ROOM, Wire.opcodeOf(frame));
	}

	function testGoldenDataFrame() {
		var frame = Wire.decode(hex2bytes(
			"0d82a174a46d6f7665a17083a179cb4004000000000000a17801a377686fa27331"
		));

		switch (frame) {
			case RoomData(type, payload):
				Assert.equals("move", type);
				var m: StringMap<Dynamic> = payload;
				Assert.equals(1, m.get("x"));
				Assert.equals(2.5, m.get("y"));
				Assert.equals("s1", m.get("who"));
			case _:
				Assert.fail("expected RoomData");
		}

		Assert.equals(Wire.OP_ROOM_DATA, Wire.opcodeOf(frame));
	}

	function testGoldenRequestResponse() {
		switch (Wire.decode(hex2bytes("1583a174a677686f616d69a16907a17080"))) {
			case RoomRequest(requestId, type, payload):
				Assert.equals(7, requestId);
				Assert.equals("whoami", type);
				var m: StringMap<Dynamic> = payload;
				Assert.equals(0, Lambda.count(m));
			case _:
				Assert.fail("expected RoomRequest");
		}

		switch (Wire.decode(hex2bytes("1682a16907a17081aa73657373696f6e5f6964a27331"))) {
			case RoomResponse(requestId, payload):
				Assert.equals(7, requestId);
				var m: StringMap<Dynamic> = payload;
				Assert.equals("s1", m.get("session_id"));
			case _:
				Assert.fail("expected RoomResponse");
		}
	}

	function testGoldenErrorFrame() {
		switch (Wire.decode(hex2bytes("0b82a76d657373616765a4626f6f6da4636f6465cd020e"))) {
			case RoomError(code, message, requestId):
				Assert.equals(526, code);
				Assert.equals("boom", message);
				// прежний формат сервера: без request_id
				Assert.equals(null, requestId);
			case _:
				Assert.fail("expected RoomError");
		}
	}

	function testGoldenErrorFrameWithRequestId() {
		// серверный кадр: {:error, %{code: 526, message: "boom", request_id: 42}}
		var frame = Wire.decode(
			hex2bytes("0b83a4636f6465cd020ea76d657373616765a4626f6f6daa726571756573745f69642a")
		);

		switch (frame) {
			case RoomError(code, message, requestId):
				Assert.equals(526, code);
				Assert.equals("boom", message);
				Assert.equals(42, requestId);
			case _:
				Assert.fail("expected RoomError");
		}
	}

	function testGoldenStateFrame() {
		switch (Wire.decode(hex2bytes(
			"0e82a7706c617965727381a2733182a179cbc000000000000000a178cb3ff0000000000000a46d6f6465a672616e6b6564"
		))) {
			case RoomState(state):
				var m: StringMap<Dynamic> = state;
				Assert.equals("ranked", m.get("mode"));
				var players: StringMap<Dynamic> = m.get("players");
				var s1: StringMap<Dynamic> = players.get("s1");
				Assert.equals(1.0, s1.get("x"));
				Assert.equals(-2.0, s1.get("y"));
			case _:
				Assert.fail("expected RoomState");
		}
	}

	function testSingleByteFrames() {
		Assert.equals("12", hex(Wire.encode(Ping(null))));
		Assert.equals("0c", hex(Wire.encode(LeaveRoom)));
		switch (Wire.decode(Bytes.ofHex("12"))) {
			case Ping(null): // ок: голый ping без payload
			case _: Assert.fail("expected bare Ping");
		}
		Assert.equals(LeaveRoom, Wire.decode(Bytes.ofHex("0c")));
		Assert.equals(Wire.OP_PING, Wire.opcodeOf(Ping(null)));
		Assert.equals(Wire.OP_LEAVE_ROOM, Wire.opcodeOf(LeaveRoom));
	}

	function testPingPayloadRoundtrip() {
		// клиентская метка времени
		var bytes = Wire.encode(Ping(mapOf("t", 12345.5)));
		Assert.equals(Wire.OP_PING, bytes.get(0));
		Assert.isTrue(bytes.length > 1);

		switch (Wire.decode(bytes)) {
			case Ping(p):
				var m:StringMap<Dynamic> = p;
				Assert.equals(12345.5, m.get("t"));
			case _:
				Assert.fail("expected Ping");
		}

		// серверное эхо: метка клиента + unix-ms штамп сервера (uint64 в msgpack)
		var echo = Wire.encode(Ping(mapOf("t", 1.5, "ts", 1700000000000.0)));
		switch (Wire.decode(echo)) {
			case Ping(p):
				var m:StringMap<Dynamic> = p;
				Assert.equals(1.5, m.get("t"));
				Assert.equals(1700000000000.0, m.get("ts"));
			case _:
				Assert.fail("expected Ping");
		}
	}

	function testEncodeRoundtrip() {
		var data = new StringMap<Dynamic>();
		data.set("room_id", "Ab3xYz9Kp");
		data.set("session_id", "sKd83jdDk2m1");
		data.set("reconnection_token", "tok");

		var frame: Frame = JoinRoom(data);
		var decoded = Wire.decode(Wire.encode(frame));

		switch (decoded) {
			case JoinRoom(d):
				Assert.equals(3, Lambda.count(d));
				Assert.equals("Ab3xYz9Kp", d.get("room_id"));
				Assert.equals("sKd83jdDk2m1", d.get("session_id"));
				Assert.equals("tok", d.get("reconnection_token"));
			case _:
				Assert.fail("expected JoinRoom");
		}

		var encoded = Wire.encode(frame);
		// байт-в-байт совместимо с однобайтовыми/однозначными векторами выше;
		// порядок ключей map не детерминирован — сверяем содержимое
		Assert.equals(Wire.OP_JOIN_ROOM, encoded.get(0));
	}

	function testEncodeRoomDataRoundtrip() {
		var bytes = Wire.encode(RoomData("move", mapOf("x", 1, "y", 2.5, "who", "s1")));
		Assert.equals(Wire.OP_ROOM_DATA, bytes.get(0));

		switch (Wire.decode(bytes)) {
			case RoomData(type, payload):
				Assert.equals("move", type);
				var m: StringMap<Dynamic> = payload;
				Assert.equals(1, m.get("x"));
				Assert.equals(2.5, m.get("y"));
				Assert.equals("s1", m.get("who"));
			case _:
				Assert.fail("expected RoomData");
		}
	}

	function testEncodeErrorRoundtrip() {
		var bytes = Wire.encode(RoomError(526, "boom"));
		Assert.equals(Wire.OP_ERROR, bytes.get(0));

		switch (Wire.decode(bytes)) {
			case RoomError(code, message, requestId):
				Assert.equals(526, code);
				Assert.equals("boom", message);
				Assert.equals(null, requestId);
			case _:
				Assert.fail("expected RoomError");
		}
	}

	function testEncodeErrorWithRequestIdRoundtrip() {
		var bytes = Wire.encode(RoomError(523, "join rejected", 7));

		switch (Wire.decode(bytes)) {
			case RoomError(code, message, requestId):
				Assert.equals(523, code);
				Assert.equals("join rejected", message);
				Assert.equals(7, requestId);
			case _:
				Assert.fail("expected RoomError");
		}
	}

	function testInvalidFrames() {
		// неизвестный опкод
		Assert.raises(() -> Wire.decode(Bytes.ofHex("01")), WireError);
		// payload не map для room_data
		Assert.raises(() -> Wire.decode(Bytes.ofHex("0da3666f6f")), WireError);
		// пустой кадр
		Assert.raises(() -> Wire.decode(Bytes.alloc(0)), WireError);
	}

	static function mapOf(k1:Dynamic, v1:Dynamic, ?k2:Dynamic, ?v2:Dynamic, ?k3:Dynamic, ?v3:Dynamic): StringMap<Dynamic> {
		var m = new StringMap<Dynamic>();
		m.set(k1, v1);
		if (k2 != null)
			m.set(k2, v2);
		if (k3 != null)
			m.set(k3, v3);
		return m;
	}

	static function hex(bytes:Bytes): String {
		var s = new StringBuf();
		for (i in 0...bytes.length)
			s.add(StringTools.hex(bytes.get(i), 2).toLowerCase());
		return s.toString();
	}
}
