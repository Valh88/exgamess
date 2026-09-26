package gamessa.tests;

import haxe.io.Bytes;
import haxe.ds.StringMap;
import gamessa.msgpack.MsgPack;
import utest.Assert;

/**
	Векторные тесты по «золотым кадрам» серверного Msgpax (Elixir) +
	roundtrip-проверки кодека.
*/
class MsgPackTest extends utest.Test {
	static function hex2bytes(hex:String): Bytes {
		var out = Bytes.alloc(Std.int(hex.length / 2));
		for (i in 0...out.length)
			out.set(i, Std.parseInt('0x' + hex.substr(i * 2, 2)));
		return out;
	}

	function testDecodeGoldenPayloadMap() {
		// Msgpax: map со строками, int, float64, bool, nil, list, вложенный map
		var m: StringMap<Dynamic> = MsgPack.decode(hex2bytes(
			"8ba47461677392a161a162aa73657373696f6e5f6964ac734b6438336a64446b326d31a573636f72652aa7726f6f6d5f6964a941623378597a394b70b27265636f6e6e656374696f6e5f746f6b656ea3746f6ba5726174696fcb3ff8000000000000a36e696cc0a66e657374656482a179920203a17801a5656d707479a0a864697361626c6564c2a6616374697665c3"
		));

		Assert.equals("Ab3xYz9Kp", m.get("room_id"));
		Assert.equals("sKd83jdDk2m1", m.get("session_id"));
		Assert.equals("tok", m.get("reconnection_token"));
		Assert.equals(42, m.get("score"));
		Assert.equals(1.5, m.get("ratio"));
		Assert.equals(true, m.get("active"));
		Assert.equals(false, m.get("disabled"));
		Assert.isNull(m.get("nil"));
		Assert.equals("", m.get("empty"));

		var tags: Array<Dynamic> = m.get("tags");
		Assert.same(["a", "b"], tags);

		var nested: StringMap<Dynamic> = m.get("nested");
		Assert.equals(1, nested.get("x"));
		var ys: Array<Dynamic> = nested.get("y");
		Assert.same([2, 3], ys);
	}

	function testDecodeGoldenInts() {
		var m: StringMap<Dynamic> = MsgPack.decode(hex2bytes(
			"8ca975696e74385f323535ccffa975696e74385f313238cc80ac75696e7433325f3635353336ce00010000ac75696e7431365f3635353335cdffffaa75696e7431365f323536cd0100aa696e74385f6e65673333d0dfac696e7431365f6e6567313239d1ff7fac666978696e745f6e65673332e0ab666978696e745f6e656731ffaa666978696e745f3132377faa666978696e745f31303064a8666978696e745f3000"
		));

		Assert.equals(255, m.get("uint8_255"));
		Assert.equals(128, m.get("uint8_128"));
		Assert.equals(65536, m.get("uint32_65536"));
		Assert.equals(65535, m.get("uint16_65535"));
		Assert.equals(256, m.get("uint16_256"));
		Assert.equals(-33, m.get("int8_neg33"));
		Assert.equals(-129, m.get("int16_neg129"));
		Assert.equals(-32, m.get("fixint_neg32"));
		Assert.equals(-1, m.get("fixint_neg1"));
		Assert.equals(127, m.get("fixint_127"));
		Assert.equals(100, m.get("fixint_100"));
		Assert.equals(0, m.get("fixint_0"));
	}

	function testDecodeGoldenListAndScalars() {
		var list: Array<Dynamic> = MsgPack.decode(hex2bytes(
			"9801fecb400c000000000000a3737472c3c092040581a16ba176"
		));
		Assert.equals(1, list[0]);
		Assert.equals(-2, list[1]);
		Assert.equals(3.5, list[2]);
		Assert.equals("str", list[3]);
		Assert.equals(true, list[4]);
		Assert.isNull(list[5]);
		Assert.same([4, 5], list[6]);
		var inner: StringMap<Dynamic> = list[7];
		Assert.equals("v", inner.get("k"));

		Assert.equals("hello", MsgPack.decode(hex2bytes("a568656c6c6f")));
	}

	function testDecodeGoldenBinary() {
		// Msgpax пакует бинари как str-формат; декодер отдаёт String
		var s:String = MsgPack.decode(hex2bytes("a4010203ff"));
		Assert.equals(4, s.length);
	}

	function testEncodeVectors() {
		Assert.equals("c0", hex(MsgPack.encode(null)));
		Assert.equals("c3", hex(MsgPack.encode(true)));
		Assert.equals("c2", hex(MsgPack.encode(false)));
		Assert.equals("00", hex(MsgPack.encode(0)));
		Assert.equals("2a", hex(MsgPack.encode(42)));
		Assert.equals("7f", hex(MsgPack.encode(127)));
		Assert.equals("cc80", hex(MsgPack.encode(128)));
		Assert.equals("cdffff", hex(MsgPack.encode(65535)));
		Assert.equals("ce00010000", hex(MsgPack.encode(65536)));
		Assert.equals("ff", hex(MsgPack.encode(-1)));
		Assert.equals("e0", hex(MsgPack.encode(-32)));
		Assert.equals("d0df", hex(MsgPack.encode(-33)));
		Assert.equals("d1ff7f", hex(MsgPack.encode(-129)));
		Assert.equals("cb3ff8000000000000", hex(MsgPack.encode(1.5)));
		Assert.equals("a568656c6c6f", hex(MsgPack.encode("hello")));
		Assert.equals("90", hex(MsgPack.encode([])));
		Assert.equals("80", hex(MsgPack.encode(new StringMap<Dynamic>())));

		// bin → bin8
		Assert.equals("c401ff", hex(MsgPack.encode(Bytes.ofHex("ff"))));
	}

	function testEncodeDecodeRoundtrip() {
		var m = new StringMap<Dynamic>();
		m.set("str", "привет"); // UTF-8
		m.set("int", -42);
		m.set("float", 0.25);
		m.set("bool", true);
		m.set("nil", null);
		m.set("arr", [1, "two", 3.0, [4]]);
		m.set("bin", Bytes.ofString("bytes"));
		var nested = new StringMap<Dynamic>();
		nested.set("deep", [new StringMap<Dynamic>()]);
		m.set("nested", nested);

		var decoded: StringMap<Dynamic> = MsgPack.decode(MsgPack.encode(m));
		Assert.equals("привет", decoded.get("str"));
		Assert.equals(-42, decoded.get("int"));
		Assert.equals(0.25, decoded.get("float"));
		Assert.equals(true, decoded.get("bool"));
		Assert.isNull(decoded.get("nil"));

		var arr: Array<Dynamic> = decoded.get("arr");
		Assert.equals(1, arr[0]);
		Assert.equals("two", arr[1]);
		Assert.equals(3, arr[2]);
		var arr2: Array<Dynamic> = arr[3];
		Assert.equals(4, arr2[0]);

		var bin: Bytes = decoded.get("bin");
		Assert.equals("bytes", bin.toString());

		var nested2: StringMap<Dynamic> = decoded.get("nested");
		var deep: Array<Dynamic> = nested2.get("deep");
		Assert.equals(1, deep.length);
	}

	function testDecodeAtTrailing() {
		// два значения подряд: 42 (0x2a) и 100 (0x64)
		var bytes = Bytes.ofHex("2a64");
		var r = MsgPack.decodeAt(bytes, 0);
		Assert.equals(42, r.value);
		Assert.equals(1, r.next);
		var r2 = MsgPack.decodeAt(bytes, r.next);
		Assert.equals(100, r2.value);
		Assert.equals(2, r2.next);
	}

	static function hex(bytes:Bytes): String {
		var s = new StringBuf();
		for (i in 0...bytes.length)
			s.add(StringTools.hex(bytes.get(i), 2).toLowerCase());
		return s.toString();
	}
}
