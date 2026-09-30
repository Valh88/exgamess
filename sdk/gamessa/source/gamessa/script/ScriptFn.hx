package gamessa.script;

/**
	Типизированный вызов скрипта: вид события + его аргументы.
	Мост приходит строкой wire-контракта (`"join" | "leave" | "message" |
	"request"` + 1-based таблица аргументов); `ScriptWire.fromWire/2`
	(вызывается из сгенерированного Lua-биндинга) разворачивает её в
	конструктор — в `ServerLogic.call`/`reply` попадают уже разобранные
	поля, позиционная индексация не нужна.

	На клиенте (предикт) конструируется напрямую:
	  `logic.call(Message("say", sid, {text: "hi"}), predictedState);`
**/
enum ScriptFn
{
	/** Клиент присоединился: args моста = [sid, auth]. */
	Join(sid:String, auth:Dynamic);

	/** Клиент ушёл: args моста = [sid, reason]. */
	Leave(sid:String, reason:String);

	/** Кадр ROOM_DATA: args моста = [type, sid, payload]. */
	Message(type:String, sid:String, payload:Dynamic);

	/**
		Request-вызов (кадр ROOM_REQUEST, ответ — RoomResponse):
		args моста = [type, sid, payload]. Идёт в `ServerLogic.reply`,
		возвращённое значение уходит запросившему клиенту; null = «нет
		обработчика» — мост отвечает ошибкой.
	**/
	Request(type:String, sid:String, payload:Dynamic);
}
