package gamessa.tests;

import gamessa.StatePatch;
import haxe.ds.StringMap;
import utest.Assert;

class StatePatchTest {
	public function new() {}

	function payload(ops:Array<Dynamic>): StringMap<Dynamic> {
		var p = new StringMap<Dynamic>();
		p.set("ops", ops);
		return p;
	}

	function op(path:Array<Dynamic>, v:Dynamic): Dynamic {
		var m = new StringMap<Dynamic>();
		m.set("p", path);
		m.set("v", v);
		return m;
	}

	function del(path:Array<Dynamic>): Dynamic {
		var m = new StringMap<Dynamic>();
		m.set("p", path);
		m.set("d", true);
		return m;
	}

	function tree(): StringMap<Dynamic> {
		var s1 = new StringMap<Dynamic>();
		s1.set("x", 0);
		s1.set("y", 0);
		var players = new StringMap<Dynamic>();
		players.set("s1", s1);
		var root = new StringMap<Dynamic>();
		root.set("mode", "ranked");
		root.set("players", players);
		return root;
	}

	function map(kvs:Array<Dynamic>): StringMap<Dynamic> {
		var m = new StringMap<Dynamic>();
		for (i in 0...Std.int(kvs.length / 2))
			m.set(kvs[i * 2], kvs[i * 2 + 1]);
		return m;
	}

	function testNestedSet() {
		var state = tree();
		state = StatePatch.apply(state, payload([op(["players", "s1", "x"], 10)]));

		var players:StringMap<Dynamic> = state.get("players");
		var s1:StringMap<Dynamic> = players.get("s1");
		Assert.equals(10, s1.get("x"));
		Assert.equals(0, s1.get("y"));
		Assert.equals("ranked", state.get("mode"));
	}

	function testMissingIntermediateCreated() {
		var state = StatePatch.apply(new StringMap<Dynamic>(), payload([op(["a", "b"], 1)]));

		var a:StringMap<Dynamic> = state.get("a");
		Assert.notNull(a);
		Assert.equals(1, a.get("b"));
	}

	function testDelete() {
		var state = tree();
		state = StatePatch.apply(state, payload([del(["players", "s1"])]));

		var players:StringMap<Dynamic> = state.get("players");
		Assert.isFalse(players.exists("s1"));
		Assert.isTrue(state.exists("mode"));
	}

	function testRootReplace() {
		var state = tree();
		state = StatePatch.apply(state, payload([op([], 42)]));

		Assert.equals(42, state);
	}

	function testSetOnNonMapStateCreatesObject() {
		var state:Dynamic = 42;
		state = StatePatch.apply(state, payload([op(["k"], "v")]));

		var m:StringMap<Dynamic> = state;
		Assert.equals("v", m.get("k"));
	}

	function testSequenceOfPatches() {
		var state:Dynamic = new StringMap<Dynamic>();
		state = StatePatch.apply(state, payload([op(["hp"], 100)]));
		state = StatePatch.apply(state, payload([op(["hp"], 80), op(["alive"], true)]));
		state = StatePatch.apply(state, payload([del(["alive"])]));

		var m:StringMap<Dynamic> = state;
		Assert.equals(80, m.get("hp"));
		Assert.isFalse(m.exists("alive"));
	}

	function testValueCanBeArray() {
		var state:Dynamic = new StringMap<Dynamic>();
		state = StatePatch.apply(state, payload([op(["l"], [1, 2, 3])]));

		var m:StringMap<Dynamic> = state;
		var arr:Array<Dynamic> = m.get("l");
		Assert.equals(3, arr.length);
		Assert.equals(3, arr[2]);
	}

	function testIgnoreUnknownPayload() {
		var state = tree();
		Assert.equals(state, StatePatch.apply(state, new StringMap<Dynamic>()));
		Assert.equals(state, StatePatch.apply(state, null));
	}

	// ------------------------------------------------------------------
	// anon-режим (представление Room.state)
	// ------------------------------------------------------------------

	function testToAnonConvertsDeep() {
		var anon = StatePatch.toAnon(tree());

		Assert.equals("ranked", anon.mode);
		Assert.equals(0, anon.players.s1.x);
		Assert.equals(0, anon.players.s1.y);
	}

	function testToAnonInsideArrays() {
		var s = map(["a", 1]);
		var anon = StatePatch.toAnon([s, 7]);
		var arr:Array<Dynamic> = anon;

		Assert.equals(2, arr.length);
		Assert.equals(1, arr[0].a);
		Assert.equals(7, arr[1]);
	}

	function testApplyAnonNestedSetAndCreate() {
		var state:Dynamic = {};
		state = StatePatch.applyAnon(state, payload([op(["players", "s1", "x"], 10)]));
		Assert.equals(10, state.players.s1.x);

		state = StatePatch.applyAnon(state, payload([op(["players", "s1", "y"], 3), op(["mode"], "ranked")]));
		Assert.equals(3, state.players.s1.y);
		Assert.equals(10, state.players.s1.x);
		Assert.equals("ranked", state.mode);
	}

	function testApplyAnonDeleteAndRootReplace() {
		var state:Dynamic = {a: 1, b: {c: 2}};
		state = StatePatch.applyAnon(state, payload([del(["b"])]));
		Assert.isFalse(Reflect.hasField(state, "b"));
		Assert.isTrue(Reflect.hasField(state, "a"));

		state = StatePatch.applyAnon(state, payload([op([], 42)]));
		Assert.equals(42, state);
	}

	function testApplyAnonConvertsOpValues() {
		var v = map(["x", 1, "y", 2]);
		var state:Dynamic = {};
		state = StatePatch.applyAnon(state, payload([op(["p"], v), op(["l"], [v])]));

		Assert.equals(1, state.p.x);
		Assert.equals(2, state.p.y);
		Assert.equals(1, state.l[0].x);
	}

	function testApplyAnonMigratesLegacyStringMapState() {
		// состояние, накопленное старым кодом (StringMap), мигрирует при первом патче
		var state:Dynamic = tree();
		state = StatePatch.applyAnon(state, payload([op(["tick"], 5)]));

		Assert.equals("ranked", state.mode);
		Assert.equals(0, state.players.s1.x);
		Assert.equals(5, state.tick);
	}

	function testApplyAnonNullState() {
		var state = StatePatch.applyAnon(null, payload([op(["k"], 1)]));
		Assert.equals(1, state.k);

		state = StatePatch.applyAnon(state, null);
		Assert.equals(1, state.k);
	}
}
