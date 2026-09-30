package gamessa.script;

/**
	Эффекты скрипта — типизированная альтернатива сырым массивам
	`["broadcast", type, payload]`. Билдер ServerLogic генерирует
	понижение enum → массивы для контракта моста; на клиенте те же
	значения интерпретируются как предсказание собственного эха.
**/
enum Effect {
	Broadcast(type:String, payload:Dynamic);
	SendTo(sid:String, type:String, payload:Dynamic);
	Kick(sid:String);
	Lock;
	Unlock;
	SetMetadata(metadata:Dynamic);
}
