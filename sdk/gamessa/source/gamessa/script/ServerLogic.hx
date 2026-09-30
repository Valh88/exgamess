package gamessa.script;

/**
	База серверных Haxe-скриптов (комнаты на Lua-VM через мост
	ExGames.Room.Logics.Lua). Тип-параметр — тип СОБСТВЕННОГО документа
	состояния скрипта (в прямом режиме он же — публикуемое состояние
	комнаты; в мульти-Lua — контент своей ветки `state_key`).

	Наследник объявляет тип состояния typedef'ом и переопределяет:

	  typedef ChatState = { seq:Int, users:haxe.DynamicAccess<String> };

	  class ChatHx extends gamessa.script.ServerLogic<ChatState> {
		public static function messages():Array<String>
		  return ["say"];

		override function init(_args:Dynamic):ChatState
		  return { seq: 0, users: {} };

		override function call(fn:ScriptFn, state:ChatState):Array<Effect> {
		  switch (fn) {
			case Message("say", sid, payload):
			  return [Broadcast("say", {...})];   // или null — без эффектов
			case _: return null;
		  }
		}

		override function tick(dt:Float, state:ChatState):Void {}
	  }

	`@:autoBuild`-макрос (`ServerLogicBuilder`) генерирует в наследника:
	  * Lua-биндинг M (main() + {эффекты, state} + `__hx_toplain` на
		границах) — только под `-lua`; имена M.schema.messages берутся из
		статической `messages()`, форма state — из typedef'а TState
		(тип и есть схема: Int/Float→number, String→string, Bool→boolean,
		DynamicAccess<X>→map, Array<X>→list, анонимная структура→таблица);
	  * `__lower` — понижение `Array<Effect>` в сырые массивы контракта
		(доступно и на клиенте — предсказание эффектов);
	  * `__stateLua` — сгенерированный литерал state-схемы (для тестов).

	Кросс-таргетность: на hl/js класс — обычный Haxe-класс (без M/биндинга),
	те же init/call/tick вызываются напрямую для клиентского предикта;
	`Room<ChatState>` типизируется тем же typedef'ом — JSON-схема для
	Haxe-скриптов не нужна.
**/
@:autoBuild(gamessa.script.ServerLogicBuilder.build())
class ServerLogic<TState>
{
	public function new()
	{
	}

	/** Старт: начальный документ состояния. */
	function init(_args:Dynamic):TState
		return throw "ServerLogic: override init()";

	/** Вызов от моста, уже типизированный. Вернуть эффекты (или null). */
	function call(_fn:ScriptFn, _state:TState):Array<Effect>
		return null;

	/**
		Ответ на request-вызов (`ScriptFn.Request`; клиент ждёт RoomResponse).
		Вернуть значение-ответ — уйдёт запросившему; null = «обработчика
		нет» — мост ответит ошибкой. Значение — любой документ
		(number/string/bool/структура/массив). Наследники `Sync` получают
		диспетчер @:rpc-методов с возвратом значения автоматически.
	**/
	function reply(_fn:ScriptFn, _state:TState):Dynamic
		return null;

	/** Тик комнаты. Мутировать state; возврат не нужен. */
	function tick(_dt:Float, _state:TState):Void
	{
	}
}
