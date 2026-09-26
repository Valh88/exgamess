package gamessa.transport;

import haxe.io.Bytes;

/**
	Транспорт WS-канала. Реализации: `WebSocketTransport` (JS + все sys-таргеты
	через hxWebSockets); при необходимости — свои реализации под конкретную
	платформу.

	Обработчики назначаются до `connect()`; после закрытия транспорт
	переиспользовать нельзя — создайте новый.
*/
interface ITransport {
	/** Соединение установлено (WS-рукопожатие завершено). */
	var onOpen:Null<Void->Void>;

	/** Бинарный кадр от сервера (протокол не использует текстовые кадры). */
	var onMessage:Null<Bytes->Void>;

	/** Соединение закрыто (в т.ч. сервером). */
	var onClose:Null<TransportClose->Void>;

	/** Ошибка транспорта. */
	var onError:Null<String->Void>;

	function connect():Void;

	function send(data:Bytes):Void;

	function close():Void;

	/** true, пока соединение открыто (после onOpen, до onClose). */
	function isOpen():Bool;
}
