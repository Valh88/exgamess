package gamessa.tests;

/**
	Компиляционный + рантайм-тест макроса gamessa.script.Schema.

	`FixtureScript` аннотирован @:build по fixture.schema.json — если
	макрос сломан, компиляция этого файла упадёт. Рантайм-ассерты
	проверяют сгенерированные типы и имена сообщений.
**/

// макрос резолвит JSON относительно файла аннотированного класса
@:build(gamessa.script.Schema.build("fixture.schema.json", "Fixture"))
class FixtureScript {}

class SchemaTest extends utest.Test {
	function testGeneratedMessageNames() {
		utest.Assert.equals("move", FixtureMsg.Move);
		utest.Assert.equals("player_joined", FixtureMsg.PlayerJoined);
		utest.Assert.equals("hit", FixtureMsg.Hit);
	}

	function testTypedefAccessOnAnonState() {
		// стейт комнаты на клиенте — анонимные объекты (StatePatch.toAnon);
		// сгенерированный typedef обязан типизировать доступ к ним безопасно
		var state:FixtureState = cast {
			players: {},
			scores: {},
			labels: ["arena", "ranked"],
			mode: "ranked",
			ticks: 12.0,
			active: true
		};

		var players:haxe.DynamicAccess<{x:Float, y:Float, hp:Float}> = state.players;
		players["s1"] = {x: 1.0, y: -2.0, hp: 100.0};

		var p = state.players["s1"];
		utest.Assert.equals(1.0, p.x);
		utest.Assert.equals(-2.0, p.y);
		utest.Assert.equals(100.0, p.hp);

		utest.Assert.equals(2, state.labels.length);
		utest.Assert.equals("ranked", state.labels[1]);
		utest.Assert.equals("ranked", state.mode);
		utest.Assert.equals(12.0, state.ticks);
		utest.Assert.isTrue(state.active);
	}
}
