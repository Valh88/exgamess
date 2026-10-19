package gamessa.wire;

import haxe.ds.StringMap;
import haxe.io.Bytes;

/**
	Кадр бинарного протокола ExGames: `[opcode :: u8][msgpack]`.
	Зеркалит `ExGames.Wire` на сервере (см. doc/PROTOCOL.md).
*/
enum Frame {
	/** Рукопожатие (сервер → клиент): room_id, session_id, reconnection_token. */
	JoinRoom(data: StringMap<Dynamic>);

	/**
		Ошибка протокола/приложения. `requestId` не null, когда ошибка —
		отклонение конкретного запроса (`Room.request`): клиент сразу
		ресолвит pending, не дожидаясь таймаута.
	*/
	RoomError(code: Int, message: String, ?requestId: Null<Int>);

	/** Согласованный выход (оба направления). */
	LeaveRoom;

	/** Игровое сообщение: {t, p}. */
	RoomData(type: Dynamic, payload: Dynamic);

	/** Полный снапшот состояния комнаты. */
	RoomState(state: Dynamic);

	/** Дельта состояния (зарезервировано). */
	RoomStatePatch(patch: Dynamic);

	/**
		Пинг (оба направления). `payload` не null, когда кадр несёт метку
		синхронизации времени: клиент шлёт `{t: <свои монотонные ms>}`,
		сервер эхирует её вместе со своим штампом `{t, ts: <unix-ms>}` —
		источник `Room.serverNow()`. Без payload кадр однобайтовый.
		Поле типизировано StringMap: динамический `payload.get(...)` на js
		ломается DCE (инлайн-методы StringMap вырезаются, динамический
		вызов инлайниться не умеет) — см. Room.handleFrame.
	*/
	Ping(?payload: StringMap<Dynamic>);

	/** Запрос с request_id (клиент → сервер): {i, t, p}. */
	RoomRequest(requestId: Int, type: Dynamic, payload: Dynamic);

	/** Ответ на request_id (сервер → клиент): {i, p}. */
	RoomResponse(requestId: Int, payload: Dynamic);

	/**
		Вход в комнату на общем сокете gateway (клиент → сервер):
		`{room_id, session_id, reconnection_token?}`. Токен задан — reattach
		в reconnect-слот, нет — attach по брони. Ответ — `Mux(JoinRoom)`.
	*/
	RoomEnter(data: StringMap<Dynamic>);

	/**
		Кадр комнаты в конверте gateway (оба направления): `r` — room_id,
		`f` — внутренний кадр протокола как есть (bin), без перекодирования.
	*/
	Mux(roomId: String, frame: Bytes);

	/**
		Канал комнаты закрыт (gateway → клиент): `{r, code, message}` —
		кик/распад комнаты/отказ входа. Общий сокет при этом жив.
	*/
	MuxClosed(roomId: String, code: Int, message: String);
}
