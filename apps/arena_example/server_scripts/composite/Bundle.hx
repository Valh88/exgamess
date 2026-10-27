package;

import gamessa.script.Composite;
import gamessa.script.Effect;
import gamessa.script.ScriptFn;

/**
	Композитный бандл: два модуля (ServerLogic-наследника) в ОДНОМ чанке
	и одной VM (`gamessa.script.Composite`; см. doc/LUA_SCRIPTING.md,
	«Композитный бандл»). Модули пишутся как обычно — свой typedef
	состояния, свои обработчики; бандл только перечисляет их и задаёт
	ключи веток общего состояния.

	Сборка: mix ex_games.scripts → ../priv/lua/composite/Bundle.lua
	(+ merged-схема Bundle.lua.schema.json). Обновление логики:
	пересборка → новые комнаты на новом чанке (живые держат старую VM —
	перезапуск через dispose).

	Демонстрация:

	* Score — объявленные типы: message "score" (+1 к очкам, broadcast),
	  request "score_get" (значение-ответ), свой счётчик тиков;
	* Ticker — catch-all (`messages(): ["*"]`): считает тики и все
	  сообщения, не объявленные другими модулями.

	Общий документ состояния комнаты: `{score: {…}, ticker: {…}}` —
	гейт set_state валидирует его по merged-схеме, клиентский
	`Sync.stateKey` режет свою ветку.
*/

typedef ScoreState = {points:Int, ticked:Int};

class Score extends gamessa.script.ServerLogic<ScoreState> {
	public static inline var VERSION = 1;

	public static function messages():Array<String>
		return ["score", "score_get"];

	override function init(_args:Dynamic):ScoreState
		return {points: 0, ticked: 0};

	override function call(fn:ScriptFn, state:ScoreState):Array<Effect> {
		return switch (fn) {
			case Message("score", sid, payload):
				state.points += payload.add;
				[Broadcast("score", {sid: sid, points: state.points, v: VERSION})];

			case _:
				null;
		}
	}

	override function reply(fn:ScriptFn, state:ScoreState):Dynamic {
		return switch (fn) {
			case Request("score_get", _, _): state.points;
			case _: null;
		}
	}

	override function tick(dt:Float, state:ScoreState):Void {
		state.ticked += Std.int(dt);
	}
}

typedef TickerState = {ticks:Int, unknown:Int};

/** catch-all: тики и все сообщения, не объявленные другими модулями. */
class Ticker extends gamessa.script.ServerLogic<TickerState> {
	public static function messages():Array<String>
		return ["*"];

	override function init(_args:Dynamic):TickerState
		return {ticks: 0, unknown: 0};

	override function call(fn:ScriptFn, state:TickerState):Array<Effect> {
		return switch (fn) {
			case Message(_, _, _):
				state.unknown++;
				null; // эффекты не нужны — изменение состояния публикуется само

			case _:
				null;
		}
	}

	override function tick(dt:Float, state:TickerState):Void {
		state.ticks += Std.int(dt);
	}
}

class Bundle {
	static function main() {
		Composite.build([
			{key: "score", logic: new Score()},
			{key: "ticker", logic: new Ticker()},
		]);
	}
}
