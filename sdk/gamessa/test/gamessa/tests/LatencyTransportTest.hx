package gamessa.tests;

import gamessa.debug.LatencyTransport;
import gamessa.transport.ITransport;
import gamessa.transport.TransportClose;
import haxe.io.Bytes;
import utest.Async;
import utest.Assert;
import utest.Test;

/**
	Дев-обёртка ITransport с задержкой/джиттером/потерями: оба направления,
	отложенная доставка событий, dropRate исходящих.
*/
class FakeBaseTransport implements ITransport {
	public var onOpen:Null<Void->Void>;
	public var onMessage:Null<Bytes->Void>;
	public var onClose:Null<TransportClose->Void>;
	public var onError:Null<String->Void>;

	public var sent:Array<Bytes> = [];
	public var closed = false;

	public function new() {}

	public function connect():Void {}

	public function send(data:Bytes):Void
		sent.push(data);

	public function close():Void
		closed = true;

	public function isOpen():Bool
		return true;
}

class LatencyTransportTest extends utest.Test {
	function testOutboundDelayed(async:Async) {
		var base = new FakeBaseTransport();
		var latency = new LatencyTransport(base, {delay: 50});
		latency.connect();

		latency.send(Bytes.ofHex("aa"));
		Assert.equals(0, base.sent.length);

		haxe.Timer.delay(() -> {
			Assert.equals(1, base.sent.length);
			async.done();
		}, 150);
	}

	function testInboundDelayed(async:Async) {
		var base = new FakeBaseTransport();
		var latency = new LatencyTransport(base, {delay: 50});
		var got:Null<Bytes> = null;
		latency.onMessage = bytes -> got = bytes;
		latency.connect();

		base.onMessage(Bytes.ofHex("bb"));
		Assert.isNull(got);

		haxe.Timer.delay(() -> {
			Assert.equals("bb", got.toHex());
			async.done();
		}, 150);
	}

	function testDropRateOneLosesOutbound(async:Async) {
		var base = new FakeBaseTransport();
		var latency = new LatencyTransport(base, {delay: 10, dropRate: 1});
		latency.connect();

		latency.send(Bytes.ofHex("cc"));
		latency.send(Bytes.ofHex("dd"));

		haxe.Timer.delay(() -> {
			Assert.equals(0, base.sent.length);
			async.done();
		}, 120);
	}

	function testCloseIsImmediate(async:Async) {
		var base = new FakeBaseTransport();
		var latency = new LatencyTransport(base, {delay: 500});
		latency.connect();

		latency.close();
		Assert.isTrue(base.closed);
		async.done();
	}
}
