package gamessa.tests;

import gamessa.script.Composite;
import gamessa.script.Effect;
import gamessa.script.ScriptFn;
import utest.Assert;

// ------------------------------------------------------------------
// стабы-модули (обычные ServerLogic-наследники, как в реальном коде)
// ------------------------------------------------------------------

typedef AState = {n:Int};

class CompModA extends gamessa.script.ServerLogic<AState> {
	public static function messages():Array<String>
		return ["ping", "a_get"];

	override function init(_a:Dynamic):AState
		return {n: 10};

		override function call(fn:ScriptFn, state:AState):Array<Effect> {
			return switch (fn) {
				case Message("ping", sid, p):
					state.n += p.add;
					[Broadcast("pong", {sid: sid, n: state.n})];
				case Join(sid, _):
					[Broadcast("hi_a", {sid: sid})];
				case Info(msg):
					[Broadcast("a_info", msg)];
				case _:
					null;
			}
		}

	override function reply(fn:ScriptFn, state:AState):Dynamic {
		return switch (fn) {
			case Request("a_get", _, _): state.n;
			case _: null;
		}
	}

	override function tick(dt:Float, state:AState):Void {
		state.n += Std.int(dt);
	}
}

typedef BState = {other:Int, joins:Int};

/** catch-all-модуль; ключ ветки берётся из stateKey (как у Sync). */
class CompModB extends gamessa.script.ServerLogic<BState> {
	public var stateKey:Null<String> = "bee";

	public static function messages():Array<String>
		return ["*"];

	override function init(_a:Dynamic):BState
		return {other: 0, joins: 0};

		override function call(fn:ScriptFn, state:BState):Array<Effect> {
			return switch (fn) {
				case Message(type, _, _):
					state.other++;
					[Broadcast("b_saw", {type: type, other: state.other})];
				case Join(_, _) | Info(_):
					state.joins++;
					[Broadcast("hi_b", {joins: state.joins})];
				case _:
					null;
			}
		}

	override function tick(dt:Float, state:BState):Void {
		state.other += Std.int(dt);
	}
}

/**
	Композитный бандл без Lua (interp): разрешение ключей, роутинг
	join/leave/message/request по модулям, catch-all, пайплайн тиков,
	merged-схема. Lua-публикация M проверяется e2e-тестами арены.
*/
class CompositeTest extends utest.Test {
	public function new() {
		super();
	}

	public function setup():Void {
		Composite.build([{key: "a", logic: new CompModA()}, {logic: new CompModB()}]);
	}

	function args(a1:Dynamic, ?a2:Dynamic, ?a3:Dynamic):Dynamic {
		final o:Dynamic = {};
		Reflect.setField(o, "1", a1);
		if (a2 != null)
			Reflect.setField(o, "2", a2);
		if (a3 != null)
			Reflect.setField(o, "3", a3);
		return o;
	}

	function firstBroadcast(fx:Array<Dynamic>):Dynamic {
		Assert.equals("broadcast", fx[0][0]);
		return fx[0][2];
	}

	function testMessagesUnionExcludesCatchAll() {
		Assert.equals("ping", Composite.__messagesWire()[0]);
		Assert.equals("a_get", Composite.__messagesWire()[1]);
		Assert.equals(2, Composite.__messagesWire().length);
	}

	function testStateSchemaMergesModuleSchemas() {
		final schema = Composite.__stateSchemaWire();
		final a = Reflect.field(schema, "a");
		Assert.equals("number", Reflect.field(a, "n"));
		// ключ B из stateKey, не из имени класса
		final bee = Reflect.field(schema, "bee");
		Assert.equals("number", Reflect.field(bee, "other"));
	}

	function testInitBuildsBranchPerModule() {
		final doc = Composite.__initWire({});
		Assert.equals(10, Reflect.field(Reflect.field(doc, "a"), "n"));
		Assert.equals(0, Reflect.field(Reflect.field(doc, "bee"), "joins"));
	}

	function testJoinFansOutToAllModulesInOrder() {
		final doc = Composite.__initWire({});
		final fx = Composite.__callWire("join", args("s1", {}), doc);

		Assert.equals(2, fx.length);
		Assert.equals("hi_a", fx[0][1]); // эффект модуля A первым
		Assert.equals("hi_b", fx[1][1]); // модуля B — вторым
		Assert.equals(1, Reflect.field(Reflect.field(doc, "bee"), "joins"));
	}

	function testInfoFansOutToAllModules() {
		final doc = Composite.__initWire({});
		final fx = Composite.__callWire("info", args({kind: "positions"}), doc);

		// оба модуля по порядку: A первым, B вторым
		Assert.equals(2, fx.length);
		Assert.equals("a_info", fx[0][1]);
		Assert.equals("hi_b", fx[1][1]);
		Assert.equals(1, Reflect.field(Reflect.field(doc, "bee"), "joins"));
	}

	function testMessageRoutedToDeclaredOwner() {
		final doc = Composite.__initWire({});
		final fx = Composite.__callWire("message", args("ping", "s1", {add: 5}), doc);

		final payload = firstBroadcast(fx);
		Assert.equals("pong", fx[0][1]);
		Assert.equals(15, payload.n);
		// catch-all НЕ получил чужой тип
		Assert.equals(0, Reflect.field(Reflect.field(doc, "bee"), "other"));
	}

	function testUnknownMessageGoesToCatchAll() {
		final doc = Composite.__initWire({});
		final fx = Composite.__callWire("message", args("whatever", "s1", {}), doc);

		Assert.equals("b_saw", fx[0][1]);
		Assert.equals(1, Reflect.field(Reflect.field(doc, "bee"), "other"));
	}

	function testRequestRoutedToOwnerReplyValue() {
		final doc = Composite.__initWire({});
		final value = Composite.__callWire("request", args("a_get", "s1", {}), doc);
		Assert.equals(10, value);
	}

	function testRequestWithoutOwnerIsNull() {
		final doc = Composite.__initWire({});
		Assert.isNull(Composite.__callWire("request", args("nobody", "s1", {}), doc));
	}

	function testTickPipesAllModules() {
		final doc = Composite.__initWire({});
		Composite.__tickWire(3.0, doc);

		Assert.equals(13, Reflect.field(Reflect.field(doc, "a"), "n")); // 10 + 3
		Assert.equals(3, Reflect.field(Reflect.field(doc, "bee"), "other"));
	}

	function testEmptyModuleListRejected() {
		Assert.raises(() -> Composite.build([]), String);
	}

	function testDuplicateKeysRejected() {
		Assert.raises(() -> Composite.build([
			{key: "x", logic: new CompModA()},
			{key: "x", logic: new CompModA()}
		]), String);
	}
}
