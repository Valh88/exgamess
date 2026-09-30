package gamessa.tests;

import gamessa.script.Effect;
import gamessa.script.ScriptArgs;

/**
	ServerLogic на не-lua таргете (interp): API и генераты билдера
	(__lower/__stateLua) без Lua-биндинга. Сам биндинг проверяется
	Elixir-интеграционным тестом Haxe-чата (arena_example).
**/

typedef SLDummyMsg = {n:Int, text:String};
typedef SLDummyState = {
	seq:Int,
	name:String,
	users:haxe.DynamicAccess<String>,
	history:haxe.DynamicAccess<SLDummyMsg>,
	tags:Array<String>,
	raw:Dynamic,
};

class SLDummy extends gamessa.script.ServerLogic<SLDummyState> {
	public static function messages():Array<String>
		return ["say", "ping"];

	override function init(_args:Dynamic):SLDummyState
		return {seq: 0, name: "x", users: {}, history: {}, tags: [], raw: null};
}

class ServerLogicTest extends utest.Test {
	function testLowerEffects() {
		utest.Assert.same(["broadcast", "say", {n: 1}], SLDummy.__lower([Broadcast("say", {n: 1})])[0]);
		utest.Assert.same(["send_to", "s1", "history", {k: 2}],
			SLDummy.__lower([SendTo("s1", "history", {k: 2})])[0]);
		utest.Assert.same(["kick", "s2"], SLDummy.__lower([Kick("s2")])[0]);
		utest.Assert.same(["lock"], SLDummy.__lower([Lock])[0]);
		utest.Assert.same(["unlock"], SLDummy.__lower([Unlock])[0]);
		utest.Assert.same(["set_metadata", {m: 3}], SLDummy.__lower([SetMetadata({m: 3})])[0]);

		// список эффектов → список массивов; null → null
		final lowered = SLDummy.__lower([Broadcast("a", {}), Kick("b")]);
		utest.Assert.equals(2, lowered.length);
		utest.Assert.isNull(SLDummy.__lower(null));
	}

	function testStateLuaFromTypedef() {
		// схема выведена из SLDummyState макросом
		final lua = SLDummy.__stateLua;
		utest.Assert.match(~/seq/, lua);
		utest.Assert.match(~/"number"/, lua);
		utest.Assert.match(~/"string"/, lua);
		utest.Assert.match(~/map/, lua);
		utest.Assert.match(~/list/, lua);
		utest.Assert.match(~/"any"/, lua);
		utest.Assert.match(~/history/, lua);
	}

	function testScriptArgsOneBased() {
		final host:Dynamic = {}; // как кодирует мост: целые ключи с 1
		#if lua
		untyped host[1] = "sid1";
		untyped host[2] = "say";
		untyped host[3] = "p";
		#else
		Reflect.setField(host, "1", "sid1");
		Reflect.setField(host, "2", "say");
		Reflect.setField(host, "3", "p");
		#end

		final args:ScriptArgs = host;
		utest.Assert.equals("sid1", args.get(1));
		utest.Assert.equals("say", args.get(2));
		utest.Assert.equals("p", args.get(3));
		utest.Assert.isNull(args.get(4));

		// фабрика клиента (предикт): массив → 1-based
		final fromArr:ScriptArgs = ScriptArgs.ofArray(["a", "b"]);
		utest.Assert.equals("a", fromArr.get(1));
		utest.Assert.equals("b", fromArr.get(2));
	}
}
