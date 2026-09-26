package gamessa.wire;

import haxe.ds.StringMap;

/**
	Кадр бинарного протокола ExGames: `[opcode :: u8][msgpack]`.
	Зеркалит `ExGames.Wire` на сервере (см. doc/PROTOCOL.md).
*/
enum Frame {
	/** Рукопожатие (сервер → клиент): room_id, session_id, reconnection_token. */
	JoinRoom(data: StringMap<Dynamic>);

	/** Ошибка протокола/приложения. */
	RoomError(code: Int, message: String);

	/** Согласованный выход (оба направления). */
	LeaveRoom;

	/** Игровое сообщение: {t, p}. */
	RoomData(type: Dynamic, payload: Dynamic);

	/** Полный снапшот состояния комнаты. */
	RoomState(state: Dynamic);

	/** Дельта состояния (зарезервировано). */
	RoomStatePatch(patch: Dynamic);

	/** Пинг (оба направления). */
	Ping;

	/** Запрос с request_id (клиент → сервер): {i, t, p}. */
	RoomRequest(requestId: Int, type: Dynamic, payload: Dynamic);

	/** Ответ на request_id (сервер → клиент): {i, p}. */
	RoomResponse(requestId: Int, payload: Dynamic);
}
