package gamessa.script;

/**
	Эффекты скрипта — типизированная альтернатива сырым массивам
	`["broadcast", type, payload]`. Билдер ServerLogic генерирует
	понижение enum → массивы для контракта моста; на клиенте те же
	значения интерпретируются как предсказание собственного эха.

	Конвенция понижения: тег = snake_case(имя конструктора),
	аргументы — по порядку объявления. Новый конструктор автоматически
	получает понижение в `__lower`; чтобы мост его применял, добавьте
	ветку в `apply_effect/2` (ExGames.Room.Logics.Lua) — whitelist
	сервера расширяется осознанно.
**/
enum Effect
{
	Broadcast(type:String, payload:Dynamic);
	SendTo(sid:String, type:String, payload:Dynamic);
	Kick(sid:String);
	Lock;
	Unlock;
	SetMetadata(metadata:Dynamic);
	/**
		Доставить сообщение в процесс самой комнаты: цепочка
		`handle_info` -> `logic_info` ВСЕХ логик комнаты. Канал
		скрипт -> соседние логики (позиции игроков для экстракции и т.п.).
		Сообщение оборачивается в `{:logic_notify, msg}`.
	**/
	NotifyRoom(msg:Dynamic);
}
