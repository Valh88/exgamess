package gamessa;

import gamessa.http.HttpError;
import gamessa.http.HttpResponse;
import gamessa.http.IHttpClient;
import gamessa.storage.IStorage;

/**
	Точка входа SDK: HTTP auth/matchmake + фабрика Room.

	    var client = new Client("http://localhost:4100");
	    client.login("vasya", "secret", auth -> {
	        client.joinOrCreate("chat", reservation -> {
	            var room = client.connectRoom(reservation);
	            room.onJoin.add(...);
	        }, err -> trace(err));
	    }, err -> trace(err));

	`endpoint` — базовый http(s)://host:port; WS-эндпоинт выводится из него
	(http→ws, https→wss).

	`verifyCert = false` отключает проверку серверного сертификата — для
	dev-стендов с самоподписанным сертификатом (hl/cpp/neko; на js сертификат
	проверяет браузер). Действует и на HTTP (дефолтный SysHttpClient), и на
	WS-транспорты комнат; свой `IHttpClient` настраивайте самостоятельно.

	Результат register/login кэшируется: `authToken` подставляется в
	Authorization всех matchmake-вызовов и персистится через `storage`.
*/
class Client {
	public var endpoint(default, null):String;
	public var http(default, null):IHttpClient;
	public var storage(get, set):IStorage;

	/** Проверять серверный сертификат (TLS). См. доку класса. */
	public var verifyCert(default, null):Bool;

	/** Кэшированный bearer-токен (после register/login/restoreAuth). */
	public var authToken(get, set):Null<String>;

	static final KEY_AUTH_TOKEN = "gamessa.auth_token";

	var _storage:Null<IStorage>;

	public function new(endpoint:String, ?http:IHttpClient, ?storage:IStorage, verifyCert:Bool = true) {
		if (StringTools.endsWith(endpoint, "/"))
			endpoint = endpoint.substr(0, endpoint.length - 1);
		this.endpoint = endpoint;
		this.verifyCert = verifyCert;
		this.http = http != null ? http : defaultHttpClient(verifyCert);
		if (storage != null)
			this.storage = storage;
	}

	function defaultHttpClient(verifyCert:Bool):IHttpClient {
		#if js
		return new gamessa.http.FetchHttpClient();
		#elseif (hl || cpp || neko || php || python || eval || java || cs)
		var client = new gamessa.http.SysHttpClient();
		client.verifyCert = verifyCert;
		return client;
		#else
		return null;
		#end
	}

	function defaultStorage():IStorage {
		#if js
		return new gamessa.storage.JsStorage();
		#elseif (hl || cpp || neko || php || python || eval || java || cs)
		return new gamessa.storage.FileStorage();
		#else
		return null;
		#end
	}

	function get_storage():IStorage {
		if (_storage == null)
			_storage = defaultStorage();
		return _storage;
	}

	function set_storage(value:IStorage):IStorage {
		return _storage = value;
	}

	function get_authToken():Null<String> {
		return http.bearerToken;
	}

	function set_authToken(value:Null<String>):Null<String> {
		http.bearerToken = value;
		if (value != null)
			storage.setItem(KEY_AUTH_TOKEN, value);
		else
			storage.removeItem(KEY_AUTH_TOKEN);
		return value;
	}

	/** Восстанавливает токен из storage (при старте приложения). */
	public function restoreAuth():Bool {
		var saved = storage.getItem(KEY_AUTH_TOKEN);
		if (saved != null)
			http.bearerToken = saved;
		return saved != null;
	}

	// ------------------------------------------------------------------
	// Auth
	// ------------------------------------------------------------------

	public function register(username:String, password:String, onSuccess:AuthData->Void, onError:MatchMakeError->Void):Void {
		post('/api/auth/register', {username: username, password: password}, data -> {
			var auth = AuthData.fromJson(data);
			authToken = auth.token;
			onSuccess(auth);
		}, onError);
	}

	public function login(username:String, password:String, onSuccess:AuthData->Void, onError:MatchMakeError->Void):Void {
		post('/api/auth/login', {username: username, password: password}, data -> {
			var auth = AuthData.fromJson(data);
			authToken = auth.token;
			onSuccess(auth);
		}, onError);
	}

	public function logout():Void {
		authToken = null;
	}

	/** `GET /api/me` — текущий пользователь. */
	public function me(onSuccess:Dynamic->Void, onError:MatchMakeError->Void):Void {
		reqGet('$endpoint/api/me', res -> onSuccess(parseJson(res.body)), err -> onError(toError(err)));
	}

	// ------------------------------------------------------------------
	// HTTP с ретраями временных сбоев
	// ------------------------------------------------------------------

	/**
		Максимум повторов HTTP-запроса при временной ошибке (сеть недоступна,
		5xx, 429). 0 — выключено (по умолчанию, поведение прежнее). Постоянные
		ошибки (прочие 4xx: неверные данные, авторизация, комната заполнена)
		не повторяются никогда.
	*/
	public var httpRetries:Int = 0;

	/** Стартовая задержка между повторами, мс (удваивается на каждую попытку). */
	public var httpRetryDelayMs:Int = 200;

	function reqGet(url:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		withRetries(fail -> http.get(url, onSuccess, fail), onError);
	}

	function reqPost(url:String, body:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		withRetries(fail -> http.post(url, body, onSuccess, fail), onError);
	}

	function reqPut(url:String, body:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		withRetries(fail -> http.put(url, body, onSuccess, fail), onError);
	}

	function reqDel(url:String, onSuccess:HttpResponse->Void, onError:HttpError->Void):Void {
		withRetries(fail -> http.del(url, onSuccess, fail), onError);
	}

	// Полностью асинхронно: ошибки HTTP-клиент доставляет колбэком (на sys —
	// из фонового потока), исключения между потоками недопустимы — попытка
	// получает свой fail, решение «повторить или сдаться» принимает он
	function withRetries(doAttempt:(HttpError->Void)->Void, onGiveUp:HttpError->Void):Void {
		doWithRetries(doAttempt, onGiveUp, 0);
	}

	function doWithRetries(doAttempt:(HttpError->Void)->Void, onGiveUp:HttpError->Void, tries:Int):Void {
		doAttempt(err -> {
			if (!transient(err) || tries >= httpRetries) {
				onGiveUp(err);
			} else {
				var delay = httpRetryDelayMs * Std.int(Math.pow(2, tries));
				haxe.Timer.delay(() -> doWithRetries(doAttempt, onGiveUp, tries + 1), delay);
			}
		});
	}

	/** Временная ли ошибка: сеть (без статуса), 5xx, 429. */
	static function transient(err:HttpError):Bool {
		if (err.status == null)
			return true;
		return err.status >= 500 || err.status == 429;
	}

	// ------------------------------------------------------------------
	// Matchmake
	// ------------------------------------------------------------------

	public function joinOrCreate(roomName:String, ?options:Dynamic, onSuccess:SeatReservation->Void, onError:MatchMakeError->Void):Void {
		matchmake('join_or_create', roomName, options, onSuccess, onError);
	}

	public function create(roomName:String, ?options:Dynamic, onSuccess:SeatReservation->Void, onError:MatchMakeError->Void):Void {
		matchmake('create', roomName, options, onSuccess, onError);
	}

	public function join(roomName:String, ?options:Dynamic, onSuccess:SeatReservation->Void, onError:MatchMakeError->Void):Void {
		matchmake('join', roomName, options, onSuccess, onError);
	}

	/** Join в конкретную комнату по room_id (без поиска по типу). */
	public function joinById(roomId:String, ?options:Dynamic, onSuccess:SeatReservation->Void, onError:MatchMakeError->Void):Void {
		var body = options == null ? {} : {options: options};
		post('/api/matchmake/join_by_id/$roomId', body, data -> onSuccess(SeatReservation.fromJson(data)), onError);
	}

	/**
		Шаг 1 reconnect-флоу: проверка reconnection-токена после обрыва.
		`sessionId` можно не передавать — токен самодостаточен.
	*/
	public function reconnect(roomId:String, reconnectionToken:String, ?sessionId:String, onSuccess:SeatReservation->Void, onError:MatchMakeError->Void):Void {
		var body:Dynamic = {reconnection_token: reconnectionToken};
		if (sessionId != null)
			body.session_id = sessionId;

		post('/api/matchmake/reconnect/$roomId', body, data -> {
			var reservation = new SeatReservation(data.room_id, data.session_id, null);
			reservation.reconnectionToken = data.reconnection_token;
			onSuccess(reservation);
		}, onError);
	}

	/**
		Живые сессии пользователя: комнаты, где он сейчас онлайн. Для экрана
		«вернуться в матч?» после перезапуска приложения (токени reconnect
		в памяти теряются); восстановление — `resumeSession`.
	*/
	public function mySessions(onSuccess:Array<LiveSession>->Void, onError:MatchMakeError->Void):Void {
		reqGet('$endpoint/api/me/sessions', res -> handle(res, data -> {
			var sessions:Array<LiveSession> = [];
			var items:Array<Dynamic> = data.sessions == null ? [] : data.sessions;
			for (item in items)
				sessions.push(new LiveSession(item.room_id, item.room_name, item.username));
			onSuccess(sessions);
		}, onError), err -> onError(toError(err)));
	}

	/**
		Восстановление сессии по identity пользователя (перезапуск приложения,
		reconnection-токен потерян): сервер находит reconnect-слот и отдаёт
		`session_id` + токен — результат как бронь с токеном, годится в
		`connectRoom` (gateway войдёт `room_enter`-ом с токеном, выделенный
		сокет — URL с reconnectionToken). Работает, пока жив слот на сервере
		(`reconnect_ttl`, по умолчанию 30с после обрыва).
	*/
	public function resumeSession(roomId:String, onSuccess:SeatReservation->Void, onError:MatchMakeError->Void):Void {
		post('/api/matchmake/resume/$roomId', {}, data -> {
			var reservation = new SeatReservation(data.room_id, data.session_id);
			reservation.reconnectionToken = data.reconnection_token;
			onSuccess(reservation);
		}, onError);
	}

	/** Листинг комнат заданного типа (или всех). */
	public function getAvailableRooms(?roomName:String, onSuccess:Array<RoomListing>->Void, onError:MatchMakeError->Void):Void {
		var url = '$endpoint/api/rooms';
		if (roomName != null)
			url += '?room_name=' + StringTools.urlEncode(roomName);

		reqGet(url, res -> handle(res, data -> {
			var rooms:Array<RoomListing> = [];
			var items:Array<Dynamic> = data.rooms == null ? [] : data.rooms;
			for (item in items)
				rooms.push(RoomListing.fromJson(item));
			onSuccess(rooms);
		}, onError), err -> onError(toError(err)));
	}

	// ------------------------------------------------------------------
	// Cloud saves
	// ------------------------------------------------------------------

	/** Сохраняет payload в слот `key` (upsert: повторный вызов перезаписывает). */
	public function saveData(key:String, payload:Dynamic, onSuccess:SaveMeta->Void, onError:MatchMakeError->Void):Void {
		put('/api/saves/$key', {payload: payload}, data -> onSuccess({key: data.key, updatedAt: data.updated_at}), onError);
	}

	/** Читает payload слота. */
	public function getData(key:String, onSuccess:Dynamic->Void, onError:MatchMakeError->Void):Void {
		reqGet('$endpoint/api/saves/$key', res -> handle(res, data -> onSuccess(data.payload), onError), err -> onError(toError(err)));
	}

	/** Список слотов пользователя (метаданные, без payload). */
	public function listSaves(onSuccess:Array<SaveMeta>->Void, onError:MatchMakeError->Void):Void {
		reqGet('$endpoint/api/saves', res -> handle(res, data -> {
			var saves:Array<SaveMeta> = [];
			var items:Array<Dynamic> = data.saves == null ? [] : data.saves;
			for (item in items)
				saves.push({key: item.key, updatedAt: item.updated_at});
			onSuccess(saves);
		}, onError), err -> onError(toError(err)));
	}

	/** Удаляет слот. */
	public function deleteSave(key:String, onSuccess:Void->Void, onError:MatchMakeError->Void):Void {
		reqDel('$endpoint/api/saves/$key', res -> {
			if (res.status < 200 || res.status >= 300)
				onError(MatchMakeError.fromJson(res.status, res.body));
			else
				onSuccess();
		}, err -> onError(toError(err)));
	}

	// ------------------------------------------------------------------
	// Leaderboard
	// ------------------------------------------------------------------

	/** Топ рейтингов игры (позиции с 1). */
	public function getLeaderboard(game:String, ?limit:Int, onSuccess:Array<LeaderboardEntry>->Void, onError:MatchMakeError->Void):Void {
		var url = '$endpoint/api/leaderboard/$game';
		if (limit != null)
			url += '?limit=' + limit;

		reqGet(url, res -> handle(res, data -> {
			var entries:Array<LeaderboardEntry> = [];
			var items:Array<Dynamic> = data.entries == null ? [] : data.entries;
			for (item in items)
				entries.push({
					position: item.position,
					userId: item.user_id,
					username: item.username,
					rating: item.rating,
					wins: item.wins,
					losses: item.losses,
					draws: item.draws
				});
			onSuccess(entries);
		}, onError), err -> onError(toError(err)));
	}

	// ------------------------------------------------------------------
	// Room-канал
	// ------------------------------------------------------------------

	/** WS-URL для подключения к комнате (по брони или reconnect). */
	public function roomWsUrl(roomId:String, sessionId:String, ?reconnectionToken:String):String {
		var url = wsEndpoint() + '/ws/$roomId?sessionId=' + StringTools.urlEncode(sessionId);
		if (reconnectionToken != null)
			url += '&reconnectionToken=' + StringTools.urlEncode(reconnectionToken);
		return url;
	}

	/** WS-URL мультиплексированного сокета (несколько комнат одним соединением). */
	public function gatewayWsUrl():String {
		return wsEndpoint() + '/ws';
	}

	/**
		Режим gateway: все новые комнаты открываются на ОДНОМ WebSocket-сокете
		(`GET /ws`, кадры RoomEnter/Mux) вместо выделенного соединения на
		комнату. По умолчанию выключен — поведение прежнее. Смешанный режим:
		конкретной комнате задайте `dedicated: true` в `connectRoom` или
		инжектируйте свой транспорт. Требует сервер с опкодами 23/25/26.
	*/
	public var useGateway:Bool = false;

	var gatewayRef:Null<Gateway> = null;

	/** Общий сокет комнат (лениво создаётся; см. `useGateway`). */
	public function gateway():Gateway {
		if (gatewayRef == null)
			gatewayRef = new Gateway(this);
		return gatewayRef;
	}

	/**
		Подключает Room по брони (шаг 2). Колбэк `onJoin` комнаты сработает
		при рукопожатии; сюда Room возвращается сразу.

		`S` — тип состояния комнаты (typedef от его wire-структуры), задаётся
		аннотацией: `var room:Room<MyState> = client.connectRoom(reservation);`
		Без аннотации состояние остаётся динамическим. Генерики Haxe стираются —
		типизация compile-time; рантайм-представление — анонимные объекты
		(динамические ключи map'ов — `Dynamic`).

		`transport` — явный транспорт (dedicated); `opts.dedicated` — выделенный
		WS даже в режиме `useGateway`; иначе в режиме `useGateway` комната
		получает канал на общем сокете.
	*/
	public function connectRoom<S>(reservation:SeatReservation, ?transport:gamessa.transport.ITransport,
			?opts:{?dedicated:Bool}):Room<S> {
		if (transport == null && (opts == null || opts.dedicated != true) && useGateway)
			transport = gateway().channelFor(reservation);

		return cast new Room(this, reservation, transport);
	}

	/** Транспорт нового Room: канал gateway в режиме useGateway, иначе выделенный WS. */
	public function defaultRoomTransport(reservation:SeatReservation):gamessa.transport.ITransport {
		if (useGateway)
			return gateway().channelFor(reservation);

		// токен есть только после resumeSession: тогда это reattach, а не новая бронь
		return new gamessa.transport.WebSocketTransport(
			roomWsUrl(reservation.roomId, reservation.sessionId, reservation.reconnectionToken), verifyCert);
	}

	/**
		Транспорт reconnect'а Room. В режиме gateway и живом общем сокете —
		канал на нём (вход по токену); иначе выделенный WS (fallback, в т.ч.
		когда gateway исчерпал попытки).
	*/
	public function reconnectTransport(res:SeatReservation, roomId:String):gamessa.transport.ITransport {
		if (useGateway && gateway().isConnected())
			return gateway().channelFor(res);

		return new gamessa.transport.WebSocketTransport(roomWsUrl(roomId, res.sessionId, res.reconnectionToken), verifyCert);
	}

	/** WS-эндпоинт, выведенный из http-эндпоинта. */
	public function wsEndpoint():String {
		if (StringTools.startsWith(endpoint, "https://"))
			return "wss://" + endpoint.substr(8);
		if (StringTools.startsWith(endpoint, "http://"))
			return "ws://" + endpoint.substr(7);
		return endpoint;
	}

	// ------------------------------------------------------------------
	// Внутреннее
	// ------------------------------------------------------------------

	function matchmake(method:String, roomName:String, ?options:Dynamic, onSuccess:SeatReservation->Void, onError:MatchMakeError->Void):Void {
		var body:Dynamic = {};
		if (options != null)
			body.options = options;

		post('/api/matchmake/$method/$roomName', body, data -> onSuccess(SeatReservation.fromJson(data)), onError);
	}

	function post(path:String, body:Dynamic, onData:Dynamic->Void, onError:MatchMakeError->Void):Void {
		reqPost('$endpoint$path', haxe.Json.stringify(body), res -> {
			handle(res, onData, onError);
		}, err -> onError(toError(err)));
	}

	function put(path:String, body:Dynamic, onData:Dynamic->Void, onError:MatchMakeError->Void):Void {
		reqPut('$endpoint$path', haxe.Json.stringify(body), res -> {
			handle(res, onData, onError);
		}, err -> onError(toError(err)));
	}

	/** Проверка статуса + разбор JSON с трансляцией ошибок сервера. */
	function handle(res:HttpResponse, onData:Dynamic->Void, onError:MatchMakeError->Void):Void {
		if (res.status < 200 || res.status >= 300) {
			onError(MatchMakeError.fromJson(res.status, res.body));
			return;
		}
		onData(parseJson(res.body));
	}

	static function parseJson(body:String):Dynamic {
		try {
			return haxe.Json.parse(body);
		} catch (e:Dynamic) {
			throw new MatchMakeError(526, 'invalid JSON response: $body');
		}
	}

	static function toError(err:HttpError):MatchMakeError {
		if (err.status != null)
			return MatchMakeError.fromJson(err.status, err.body == null ? err.message : err.body);
		return new MatchMakeError(0, err.message);
	}
}
