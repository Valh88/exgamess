package gamessa.wire;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.ds.StringMap;
import gamessa.msgpack.MsgPack;

/**
	Кодирование/декодирование кадров протокола `[opcode :: u8][msgpack]` +
	константы (опкоды, коды ошибок 520–526, коды закрытия 4000/4001/4002/4003/4010).
	Типы кадров — `Frame`, ошибки — `WireError`.
*/
class Wire {
	public static inline var OP_JOIN_ROOM = 10;
	public static inline var OP_ERROR = 11;
	public static inline var OP_LEAVE_ROOM = 12;
	public static inline var OP_ROOM_DATA = 13;
	public static inline var OP_ROOM_STATE = 14;
	public static inline var OP_ROOM_STATE_PATCH = 15;
	public static inline var OP_PING = 18;
	public static inline var OP_ROOM_REQUEST = 21;
	public static inline var OP_ROOM_RESPONSE = 22;
	public static inline var OP_ROOM_ENTER = 23;
	public static inline var OP_MUX = 25;
	public static inline var OP_MUX_CLOSED = 26;

	// Коды ошибок протокола.
	public static inline var ERR_UNKNOWN_ROOM_TYPE = 520;
	public static inline var ERR_NO_ROOM = 521;
	public static inline var ERR_UNKNOWN_ROOM = 522;
	public static inline var ERR_ROOM_FULL = 523;
	public static inline var ERR_JOIN_REJECTED = 523;
	public static inline var ERR_AUTH_FAILED = 525;
	public static inline var ERR_INTERNAL = 526;

	// Коды закрытия WS.
	public static inline var CLOSE_NORMAL = 4000;
	public static inline var CLOSE_SHUTDOWN = 4001;
	public static inline var CLOSE_ERROR = 4002;
	public static inline var CLOSE_RECONNECT_TIMEOUT = 4003;
	public static inline var CLOSE_EXPIRED = 4010;

	public static function encode(frame: Frame): Bytes {
		var out = new BytesBuffer();
		out.addByte(opcodeOf(frame));

		switch (frame) {
			case LeaveRoom:
				// однобайтовый кадр
			case Ping(payload):
				// без payload — однобайтовый; с payload — метка синхронизации времени
				if (payload != null)
					out.add(MsgPack.encode(payload));
			case JoinRoom(data):
				out.add(MsgPack.encode(data));
			case RoomError(code, message, requestId):
				var m = map2("code", code, "message", message);

				if (requestId != null)
					m.set("request_id", requestId);

				out.add(MsgPack.encode(m));
			case RoomData(type, payload):
				out.add(MsgPack.encode(map2("t", type, "p", payload)));
			case RoomState(state):
				out.add(MsgPack.encode(state));
			case RoomStatePatch(patch):
				out.add(MsgPack.encode(patch));
			case RoomRequest(requestId, type, payload):
				var m = map2("i", requestId, "t", type);
				m.set("p", payload);
				out.add(MsgPack.encode(m));
			case RoomResponse(requestId, payload):
				out.add(MsgPack.encode(map2("i", requestId, "p", payload)));
			case RoomEnter(data):
				out.add(MsgPack.encode(data));
			case Mux(roomId, frame):
				// внутренний кадр уходит как есть (Bytes → msgpack bin)
				var m = new StringMap<Dynamic>();
				m.set("r", roomId);
				m.set("f", frame);
				out.add(MsgPack.encode(m));
			case MuxClosed(roomId, code, message):
				var m = new StringMap<Dynamic>();
				m.set("r", roomId);
				m.set("code", code);
				m.set("message", message);
				out.add(MsgPack.encode(m));
		}

		return out.getBytes();
	}

	public static function decode(bytes: Bytes): Frame {
		if (bytes.length == 0)
			throw new WireError("empty frame");

		var op = bytes.get(0);
		var payload: Dynamic = null;

		switch (op) {
			case OP_PING:
				if (bytes.length > 1) {
					try {
						payload = MsgPack.decode(bytes.sub(1, bytes.length - 1));
					} catch (e: Dynamic) {
						throw new WireError('invalid ping payload (op $op): $e');
					}
					if (!Std.isOfType(payload, StringMap))
						throw new WireError('ping payload (op $op) must be a map');
				}
				return Ping(payload);
			case OP_LEAVE_ROOM:
				return LeaveRoom;
			case _:
				try {
					payload = MsgPack.decode(bytes.sub(1, bytes.length - 1));
				} catch (e: Dynamic) {
					throw new WireError('invalid frame payload (op $op): $e');
				}
		}

		switch (op) {
			case OP_JOIN_ROOM:
				return JoinRoom(checkMap(payload, op));
			case OP_ERROR:
				var m = checkMap(payload, op);
				return RoomError(m.get("code"), m.get("message"), m.get("request_id"));
			case OP_ROOM_DATA:
				var m = checkMap(payload, op);
				return RoomData(m.get("t"), m.get("p"));
			case OP_ROOM_STATE:
				return RoomState(payload);
			case OP_ROOM_STATE_PATCH:
				return RoomStatePatch(payload);
			case OP_ROOM_REQUEST:
				var m = checkMap(payload, op);
				return RoomRequest(m.get("i"), m.get("t"), m.get("p"));
		case OP_ROOM_RESPONSE:
			var m = checkMap(payload, op);
			return RoomResponse(m.get("i"), m.get("p"));
		case OP_ROOM_ENTER:
			return RoomEnter(checkMap(payload, op));
		case OP_MUX:
			var m = checkMap(payload, op);
			return Mux(m.get("r"), muxFrame(m.get("f"), op));
		case OP_MUX_CLOSED:
			var m = checkMap(payload, op);
			return MuxClosed(m.get("r"), m.get("code"), m.get("message"));
		case _:
			throw new WireError('unknown opcode $op');
		}
	}

	public static function opcodeOf(frame: Frame): Int {
		return switch (frame) {
			case JoinRoom(_): OP_JOIN_ROOM;
			case RoomError(_, _): OP_ERROR;
			case LeaveRoom: OP_LEAVE_ROOM;
			case RoomData(_, _): OP_ROOM_DATA;
			case RoomState(_): OP_ROOM_STATE;
			case RoomStatePatch(_): OP_ROOM_STATE_PATCH;
			case Ping(_): OP_PING;
			case RoomRequest(_, _, _): OP_ROOM_REQUEST;
			case RoomResponse(_, _): OP_ROOM_RESPONSE;
			case RoomEnter(_): OP_ROOM_ENTER;
			case Mux(_, _): OP_MUX;
			case MuxClosed(_, _, _): OP_MUX_CLOSED;
		};
	}

	// внутренний кадр конверта: msgpack bin приходит как Bytes; str-закодированный
	// внутренний кадр (валидный utf-8) — как String, нормализуем
	static function muxFrame(f: Dynamic, op: Int): Bytes {
		if (Std.isOfType(f, Bytes))
			return f;
		if (Std.isOfType(f, String))
			return Bytes.ofString(f);
		throw new WireError('mux frame (op $op) payload must be bytes');
	}

	static function checkMap(payload: Dynamic, op: Int): StringMap<Dynamic> {
		if (Std.isOfType(payload, StringMap))
			return payload;
		throw new WireError('frame (op $op) payload must be a map');
	}

	static function map2(k1: String, v1: Dynamic, k2: String, v2: Dynamic): StringMap<Dynamic> {
		var m = new StringMap<Dynamic>();
		m.set(k1, v1);
		m.set(k2, v2);
		return m;
	}
}
