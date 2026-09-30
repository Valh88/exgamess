package gamessa.tests;

import gamessa.script.Effect;

/**
	Sync (@:rpc) на не-lua таргете (interp, `-D gamessa-server`):
	сгенерированные messages()/call/reply-диспетчеры и серверные стабы.
	Клиентские стабы (без define) — compile-проверка test_client.hxml;
	их кадровая эквивалентность доказывается E2E sync_chat.
**/
typedef SyncDummyState =
{
	seq:Int,
	name:String,
};

class SyncDummy extends gamessa.script.Sync<SyncDummyState>
{
	@:rpc public function say(text:String):Array<Effect>
		return [Broadcast("say", {t: text, by: caller})];

	@:rpc public function seq():Int
		return state.seq;

	@:rpc public function echo(a:Int, b:String):String
		return b + a;

	override function onJoin(sid:String, _auth:Dynamic):Array<Effect>
		return [Broadcast("joined", {sid: sid})];

	override function onLeave(sid:String, _reason:String):Array<Effect>
		return [Broadcast("left", {sid: sid})];

	// call/reply — private (контракт моста); для тестов — проходные обёртки
	public function callPub(fn:gamessa.script.ScriptFn, s:SyncDummyState):Array<Effect>
		return call(fn, s);

	public function replyPub(fn:gamessa.script.ScriptFn, s:SyncDummyState):Dynamic
		return reply(fn, s);
}

class SyncTest extends utest.Test
{
	var d:SyncDummy;
	var st:SyncDummyState;

	function setup()
	{
		d = new SyncDummy();
		st = {seq: 7, name: "x"};
	}

	function testMessagesFromRpc()
	{
		// порядок объявления @:rpc; собственной messages() у SyncDummy нет
		utest.Assert.same(["say", "seq", "echo"], SyncDummy.messages());
	}

	function testCallDispatcherEffects()
	{
		// send-метод: декод payload + caller + эффекты
		final e = d.callPub(Message("say", "s1", {text: "hi"}), st);
		utest.Assert.same([["broadcast", "say", {t: "hi", by: "s1"}]], SyncDummy.__lower(e));

		// Join/Leave → onJoin/onLeave
		utest.Assert.same([["broadcast", "joined", {sid: "s2"}]], SyncDummy.__lower(d.callPub(Join("s2", null), st)));
		utest.Assert.same([["broadcast", "left", {sid: "s3"}]], SyncDummy.__lower(d.callPub(Leave("s3", "kick"), st)));

		// неизвестный тип и request-путь через call() — без эффектов
		utest.Assert.isNull(d.callPub(Message("nope", "s1",
			{
			}), st));
		utest.Assert.isNull(d.callPub(Request("say", "s1", {text: "x"}), st));
	}

	function testCallDispatcherArgs()
	{
		// несколько аргументов: декод по именам полей, типизированные локалы
		utest.Assert.equals("ab12", d.replyPub(Request("echo", "s1", {a: 12, b: "ab"}), st));
	}

	function testReplyDispatcherValue()
	{
		// request-метод возвращает значение (state виден диспетчеру)
		utest.Assert.equals(7, d.replyPub(Request("seq", "s1",
			{
			}), st));
		utest.Assert.isNull(d.replyPub(Request("nope", "s1",
			{
			}), st));
		utest.Assert.isNull(d.replyPub(Message("seq", "s1",
			{
			}), st));
		utest.Assert.isNull(d.replyPub(Join("s1", null), st));
	}

	function testCallerAndStateSetByDispatcher()
	{
		d.callPub(Message("say", "s9", {text: "!"}), st);
		utest.Assert.equals("s9", d.caller);
		utest.Assert.same(st, d.state);

		d.replyPub(Request("seq", "s4",
			{
			}), st);
		utest.Assert.equals("s4", d.caller);
	}

	#if gamessa_server
	function testServerStubDelegatesLocally()
	{
		// серверный стаб выполняет тело локально (композиция @:rpc-методов);
		// state/caller заполняет диспетчер — вне его say работает, seq видит
		// state только после диспетчеризации
		utest.Assert.same([Broadcast("say", {t: "hi", by: null})], d.say("hi"));
		d.callPub(Request("seq", "s1",
			{
			}), st);
		utest.Assert.equals(7, d.seq());
		utest.Assert.isNull(d.caller); // стаб напрямую — caller не выставлен
	}
	#end

	function testSchemaFromTypedefThroughSync()
	{
		// TState разрешён через промежуточный Sync (подстановка параметров)
		utest.Assert.match(~/seq/, SyncDummy.__stateLua);
		utest.Assert.match(~/"number"/, SyncDummy.__stateLua);
		utest.Assert.match(~/name/, SyncDummy.__stateLua);
	}
}
