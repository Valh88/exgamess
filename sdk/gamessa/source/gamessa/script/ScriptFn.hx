package gamessa.script;

/**
	Типизированный вызов скрипта: вид события + его аргументы.
	Мост приходит строкой wire-контракта (`"join" | "leave" | "message"` +
	1-based таблица аргументов); `ScriptWire.fromWire/2` (вызывается из
	сгенерированного Lua-биндинга) разворачивает её в конструктор — в
	`ServerLogic.call` попадают уже разобранные поля, позиционная
	индексация не нужна.

	На клиенте (предикт) конструируется напрямую:
	  `logic.call(Message("say", sid, {text: "hi"}), predictedState);`
**/
enum ScriptFn {
	/** Клиент присоединился: args моста = [sid, auth]. */
	Join(sid:String, auth:Dynamic);

	/** Клиент ушёл: args моста = [sid, reason]. */
	Leave(sid:String, reason:String);

	/** Кадр ROOM_DATA: args моста = [type, sid, payload]. */
	Message(type:String, sid:String, payload:Dynamic);
}
