package gamessa.msgpack;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.ds.StringMap;

/**
	Минимальный MessagePack-кодек, совместимый по конвенциям с серверным
	Msgpax (Elixir): map'ы со string-ключами, str/bin, целые минимальным
	форматом, дробные — float64. Ext-типы не поддерживаются.

	Декодирование: map → `haxe.ds.StringMap<Dynamic>`, array → `Array<Dynamic>`,
	числа → `Int` (или `Float` для 64-бит), str → `String`, bin → `Bytes`.

	Кодирование принимает `null`, `Bool`, `Int`, `Float`, `String`, `Bytes`,
	`Array<Dynamic>`, `Map<String,Dynamic>` и анонимные объекты (string-ключи).
	Ошибки — `MsgPackError`.
*/
class MsgPack {
	// ------------------------------------------------------------------
	// Encode
	// ------------------------------------------------------------------

	public static function encode(value: Dynamic): Bytes {
		var b = new BytesBuffer();
		encodeValue(b, value);
		return b.getBytes();
	}

	static function encodeValue(b: BytesBuffer, value: Dynamic): Void {
		if (value == null) {
			b.addByte(0xc0);
		} else if (Std.isOfType(value, Bool)) {
			b.addByte(value == true ? 0xc3 : 0xc2);
		} else if (Std.isOfType(value, Int)) {
			encodeInt(b, value);
		} else if (Std.isOfType(value, Float)) {
			b.addByte(0xcb);
			var i = haxe.io.FPHelper.doubleToI64(value);
			writeU32(b, haxe.Int64.getHigh(i));
			writeU32(b, haxe.Int64.getLow(i));
		} else if (Std.isOfType(value, String)) {
			encodeString(b, value);
		} else if (Std.isOfType(value, Bytes)) {
			encodeBinary(b, value);
		} else if (Std.isOfType(value, Array)) {
			encodeArray(b, value);
		} else if (Std.isOfType(value, StringMap)) {
			encodeMap(b, value);
		} else {
			// анонимный объект: поля как string-ключи
			var fields = Reflect.fields(value);
			encodeMapHeader(b, fields.length);
			for (f in fields) {
				encodeString(b, f);
				encodeValue(b, Reflect.field(value, f));
			}
		}
	}

	static function encodeInt(b: BytesBuffer, v: Int): Void {
		if (v >= 0 && v <= 127) {
			b.addByte(v);
		} else if (v < 0 && v >= -32) {
			b.addByte(0x100 + v);
		} else if (v > 0) {
			if (v <= 0xff) {
				b.addByte(0xcc);
				b.addByte(v);
			} else if (v <= 0xffff) {
				b.addByte(0xcd);
				addUInt16(b, v);
			} else {
				b.addByte(0xce);
				writeU32(b, v);
			}
		} else {
			if (v >= -128) {
				b.addByte(0xd0);
				b.addByte(v & 0xff);
			} else if (v >= -32768) {
				b.addByte(0xd1);
				addUInt16(b, v & 0xffff);
			} else {
				b.addByte(0xd2);
				writeU32(b, v);
			}
		}
	}

	static function encodeString(b: BytesBuffer, s: String): Void {
		var bytes = Bytes.ofString(s);
		encodeWithLength(b, bytes, 0xa0, 0xd9, 0xda, 0xdb);
	}

	static function encodeBinary(b: BytesBuffer, bytes: Bytes): Void {
		encodeWithLength(b, bytes, -1, 0xc4, 0xc5, 0xc6);
	}

	static function encodeWithLength(b: BytesBuffer, bytes: Bytes, fixPrefix:Int, p8:Int, p16:Int, p32:Int): Void {
		var len = bytes.length;
		if (fixPrefix >= 0 && len <= 31) {
			b.addByte(fixPrefix | len);
		} else if (len <= 0xff) {
			b.addByte(p8);
			b.addByte(len);
		} else if (len <= 0xffff) {
			b.addByte(p16);
			addUInt16(b, len);
		} else {
			b.addByte(p32);
			writeU32(b, len);
		}
		b.add(bytes);
	}

	static function encodeArray(b: BytesBuffer, arr: Array<Dynamic>): Void {
		encodeCollectionHeader(b, arr.length, 0x90, 0xdc, 0xdd);
		for (v in arr)
			encodeValue(b, v);
	}

	static function encodeMap(b: BytesBuffer, map: StringMap<Dynamic>): Void {
		var keys = [for (k in map.keys()) k];
		encodeCollectionHeader(b, keys.length, 0x80, 0xde, 0xdf);
		for (k in keys) {
			encodeString(b, k);
			encodeValue(b, map.get(k));
		}
	}

	static function encodeMapHeader(b: BytesBuffer, count: Int): Void {
		encodeCollectionHeader(b, count, 0x80, 0xde, 0xdf);
	}

	static function encodeCollectionHeader(b: BytesBuffer, count: Int, fixPrefix:Int, p16:Int, p32:Int): Void {
		if (count <= 15) {
			b.addByte(fixPrefix | count);
		} else if (count <= 0xffff) {
			b.addByte(p16);
			addUInt16(b, count);
		} else {
			b.addByte(p32);
			writeU32(b, count);
		}
	}

	static inline function addUInt16(b: BytesBuffer, v: Int): Void {
		b.addByte((v >> 8) & 0xff);
		b.addByte(v & 0xff);
	}

	static inline function writeU32(b: BytesBuffer, v: Int): Void {
		b.addByte((v >>> 24) & 0xff);
		b.addByte((v >>> 16) & 0xff);
		b.addByte((v >>> 8) & 0xff);
		b.addByte(v & 0xff);
	}

	// ------------------------------------------------------------------
	// Decode
	// ------------------------------------------------------------------

	public static function decode(bytes: Bytes): Dynamic {
		var r = decodeAt(bytes, 0);
		return r.value;
	}

	public static function decodeAt(bytes: Bytes, pos: Int): DecodeResult {
		var byte = bytes.get(pos);
		pos++;

		// positive fixint
		if (byte <= 0x7f)
			return {value: byte, next: pos};
		// fixmap
		if (byte >= 0x80 && byte <= 0x8f)
			return decodeMap(bytes, pos, byte & 0x0f);
		// fixarray
		if (byte >= 0x90 && byte <= 0x9f)
			return decodeArray(bytes, pos, byte & 0x0f);
		// fixstr
		if (byte >= 0xa0 && byte <= 0xbf)
			return decodeString(bytes, pos, byte & 0x1f);
		// negative fixint
		if (byte >= 0xe0)
			return {value: byte - 0x100, next: pos};

		switch (byte) {
			case 0xc0: return {value: null, next: pos};
			case 0xc2: return {value: false, next: pos};
			case 0xc3: return {value: true, next: pos};
			case 0xc4: return decodeBinary(bytes, pos + 1, u8(bytes, pos));
			case 0xc5: return decodeBinary(bytes, pos + 2, u16(bytes, pos));
			case 0xc6: return decodeBinary(bytes, pos + 4, u32(bytes, pos));
			case 0xca:
				// float32: биты big-endian → reinterpret через FPHelper
				var v = haxe.io.FPHelper.i32ToFloat(u32(bytes, pos));
				return {value: v, next: pos + 4};
			case 0xcb:
				// float64: little-endian половины битовой записи
				var v = haxe.io.FPHelper.i64ToDouble(u32(bytes, pos + 4), u32(bytes, pos));
				return {value: v, next: pos + 8};
			case 0xcc: return {value: u8(bytes, pos), next: pos + 1};
			case 0xcd: return {value: u16(bytes, pos), next: pos + 2};
			case 0xce: return {value: u32(bytes, pos), next: pos + 4};
			case 0xcf: return {value: u64(bytes, pos), next: pos + 8};
			case 0xd0: return {value: (bytes.get(pos) << 24) >> 24, next: pos + 1};
			case 0xd1: return {value: (u16(bytes, pos) << 16) >> 16, next: pos + 2};
			case 0xd2: return {value: u32(bytes, pos), next: pos + 4};
			case 0xd3: return {value: i64(bytes, pos), next: pos + 8};
			case 0xd9: return decodeString(bytes, pos + 1, u8(bytes, pos));
			case 0xda: return decodeString(bytes, pos + 2, u16(bytes, pos));
			case 0xdb: return decodeString(bytes, pos + 4, u32(bytes, pos));
			case 0xdc: return decodeArray(bytes, pos + 2, u16(bytes, pos));
			case 0xdd: return decodeArray(bytes, pos + 4, u32(bytes, pos));
			case 0xde: return decodeMap(bytes, pos + 2, u16(bytes, pos));
			case 0xdf: return decodeMap(bytes, pos + 4, u32(bytes, pos));
			case _:
				throw new MsgPackError('unsupported msgpack format 0x${StringTools.hex(byte, 2)} at $pos');
		}
	}

	static function decodeString(bytes: Bytes, pos: Int, len: Int): DecodeResult {
		return {value: bytes.getString(pos, len), next: pos + len};
	}

	static function decodeBinary(bytes: Bytes, pos: Int, len: Int): DecodeResult {
		return {value: bytes.sub(pos, len), next: pos + len};
	}

	static function decodeArray(bytes: Bytes, pos: Int, count: Int): DecodeResult {
		var arr = new Array<Dynamic>();
		for (_ in 0...count) {
			var r = decodeAt(bytes, pos);
			arr.push(r.value);
			pos = r.next;
		}
		return {value: arr, next: pos};
	}

	static function decodeMap(bytes: Bytes, pos: Int, count: Int): DecodeResult {
		var map = new StringMap<Dynamic>();
		for (_ in 0...count) {
			var key = decodeAt(bytes, pos);
			pos = key.next;
			if (!Std.isOfType(key.value, String))
				throw new MsgPackError('msgpack map key must be a string');
			var val = decodeAt(bytes, pos);
			pos = val.next;
			map.set(key.value, val.value);
		}
		return {value: map, next: pos};
	}

	static inline function u8(b: Bytes, pos: Int): Int
		return b.get(pos);

	static inline function u16(b: Bytes, pos: Int): Int
		return (b.get(pos) << 8) | b.get(pos + 1);

	// big-endian u32; битовая запись как signed Int (для значений < 2^31
	// совпадает с unsigned, большие протоколом не используются)
	static inline function u32(b: Bytes, pos: Int): Int
		return (b.get(pos) << 24) | (b.get(pos + 1) << 16) | (b.get(pos + 2) << 8) | b.get(pos + 3);

	// 64-битные значения читаем как Float (безопасно до 2^53 — больше
	// протокол не использует; JS-числа всё равно Float).
	static function u64(b: Bytes, pos: Int): Float {
		var hi: Float = u32(b, pos);
		if (hi < 0)
			hi += 4294967296.0;
		var lo: Float = u32(b, pos + 4);
		if (lo < 0)
			lo += 4294967296.0;
		return hi * 4294967296.0 + lo;
	}

	static function i64(b: Bytes, pos: Int): Float {
		var v = u64(b, pos);
		return v >= 9223372036854775808.0 ? v - 18446744073709551616.0 : v;
	}
}
