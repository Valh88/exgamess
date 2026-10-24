package gamessa;

/**
	Человекочитаемые тексты ошибок по кодам (`MatchMakeError.code`, WS close
	коды): убирают из игр копипасту switch-ей. Коды — см. doc/PROTOCOL.md.

		var text = ErrorText.userFacing(err);            // ru (по умолчанию)
		var text = ErrorText.userFacing(err, "en");

	Исходное серверное сообщение дописывается в скобках — для логов/поддержки;
	не показывайте его игроку, если не уверены в его содержимом.
*/
class ErrorText {
	/** Текст по ошибке (код берётся из MatchMakeError). */
	public static function userFacing(err:MatchMakeError, lang:String = "ru"):String {
		return ofCode(err.code, lang, err.message);
	}

	/** Текст по коду: протокольные 520–526, HTTP 4xx/5xx, close 4000-е, 0 — сеть. */
	public static function ofCode(code:Int, lang:String = "ru", ?details:String):String {
		var dict = lang == "en" ? EN : RU;
		var text = dict.get(code);

		if (text == null)
			text = lang == "en" ? 'Error $code' : 'Ошибка $code';

		if (details != null && details != "")
			text += ' ($details)';

		return text;
	}

	static final RU:Map<Int, String> = [
		0 => "Нет соединения с сервером",
		400 => "Неверный запрос",
		401 => "Требуется вход в аккаунт",
		403 => "Доступ запрещён",
		404 => "Не найдено",
		409 => "Это имя уже занято",
		422 => "Неверные данные (проверьте поля)",
		423 => "Комната закрыта для подключения",
		429 => "Слишком много запросов, попробуйте позже",
		500 => "Внутренняя ошибка сервера",
		520 => "Такой тип комнаты не зарегистрирован",
		521 => "Подходящей комнаты нет",
		522 => "Комната или сессия не найдены",
		523 => "Комната заполнена",
		525 => "Ошибка авторизации",
		526 => "Внутренняя ошибка сервера",
		4000 => "Соединение закрыто",
		4001 => "Сервер перезапускается",
		4002 => "Соединение прервано (ошибка протокола)",
		4003 => "Не удалось переподключиться",
		4010 => "Сессия истекла"
	];

	static final EN:Map<Int, String> = [
		0 => "No connection to the server",
		400 => "Bad request",
		401 => "Sign in required",
		403 => "Access denied",
		404 => "Not found",
		409 => "This name is already taken",
		422 => "Invalid input (check the fields)",
		423 => "The room is closed for joining",
		429 => "Too many requests, try again later",
		500 => "Internal server error",
		520 => "This room type is not registered",
		521 => "No matching room",
		522 => "Room or session not found",
		523 => "The room is full",
		525 => "Authentication error",
		526 => "Internal server error",
		4000 => "Connection closed",
		4001 => "The server is restarting",
		4002 => "Connection dropped (protocol error)",
		4003 => "Could not reconnect",
		4010 => "Session expired"
	];
}
