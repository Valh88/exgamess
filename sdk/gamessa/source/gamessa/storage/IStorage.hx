package gamessa.storage;

/**
	Персистентное key-value хранилище (reconnection-токены и пр.).
	Реализации: `JsStorage` (localStorage), `FileStorage` (sys-таргеты).
	Синхронное API — объём данных крошечный (токены, id сессий).
*/
interface IStorage {
	function getItem(key:String):Null<String>;
	function setItem(key:String, value:String):Void;
	function removeItem(key:String):Void;
}
