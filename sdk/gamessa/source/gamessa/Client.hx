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

	Результат register/login кэшируется: `authToken` подставляется в
	Authorization всех matchmake-вызовов и персистится через `storage`.
*/
class Client {
	public var endpoint(default, null):String;
	public var http(default, null):IHttpClient;
	public var storage(get, set):IStorage;

	/** Кэшированный bearer-токен (после register/login/restoreAuth). */
	public var authToken(get, set):Null<String>;

	static final KEY_AUTH_TOKEN = "gamessa.auth_token";

	var _storage:Null<IStorage>;

	public function new(endpoint:String, ?http:IHttpClient, ?storage:IStorage) {
		if (StringTools.endsWith(endpoint, "/"))
			endpoint = endpoint.substr(0, endpoint.length - 1);
		this.endpoint = endpoint;
		this.http = http != null ? http : defaultHttpClient();
		if (storage != null)
			this.storage = storage;
	}

	static function defaultHttpClient():IHttpClient {
		#if js
		return new gamessa.http.FetchHttpClient();
		#elseif (hl || cpp || neko || php || python || eval || java || cs)
		return new gamessa.http.SysHttpClient();
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
		http.get('$endpoint/api/me', res -> onSuccess(parseJson(res.body)), err -> onError(toError(err)));
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

	/** Листинг комнат заданного типа (или всех). */
	public function getAvailableRooms(?roomName:String, onSuccess:Array<RoomListing>->Void, onError:MatchMakeError->Void):Void {
		var url = '$endpoint/api/rooms';
		if (roomName != null)
			url += '?room_name=' + StringTools.urlEncode(roomName);

		http.get(url, res -> handle(res, data -> {
			var rooms:Array<RoomListing> = [];
			var items:Array<Dynamic> = data.rooms == null ? [] : data.rooms;
			for (item in items)
				rooms.push(RoomListing.fromJson(item));
			onSuccess(rooms);
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

	/**
		Подключает Room по брони (шаг 2). Колбэк `onJoin` комнаты сработает
		при рукопожатии; сюда Room возвращается сразу.
	*/
	public function connectRoom(reservation:SeatReservation, ?transport:gamessa.transport.ITransport):Room {
		return new Room(this, reservation, transport);
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
		http.post('$endpoint$path', haxe.Json.stringify(body), res -> {
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
