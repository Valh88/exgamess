package gamessa.script;

/**
	Sync — `ServerLogic<TState>` с типизированными @:rpc-методами, общий
	для сервера и клиента. Один и тот же класс компилируется:

	* **сервер** (`-D gamessa-server`, Lua-чанк через `gamessa run`) —
	  @:rpc-тела выполняются: send-методы (возврат `Void`/`Array<Effect>`)
	  диспетчеризуются из `call` по имени кадра, request-методы (любой
	  другой возврат) — из `reply`, значение уходит запросившему клиенту;
	* **клиент** (js/hl, без define) — @:rpc-методы становятся стабами:
	  `chat.say("hi")` → `room.send("say", …)`, `chat.seq(v -> …)` →
	  `room.request("seq", …)`. Состояние типизировано тем же typedef'ом
	  (`Room<TState>`); после `bind` поле `state` держит последний
	  снапшот (onStateChange) — его видят тела clients-событий.

	  var chat = new ChatSync();
	  chat.bind(room);
	  chat.say("привет");
	  chat.seq(v -> trace("seq = " + v));

	Режимы @:rpc (направление вызова):

	* `@:rpc` / `@:rpc(server)` — клиент → сервер (умолчание). На клиенте
	  стаб шлёт; на сервере тело исполняется. Возврат `Void`/`Array<Effect>`
	  = send-путь, любой другой = request-путь (ответ значением).
	* `@:rpc(clients)` — сервер → клиенты (типизированное событие).
	  Только `Void`. На сервере стаб понижает вызов в
	  `[Broadcast(имя, {аргументы})]` — верните эффекты из call/onJoin/
	  onLeave (из tick эффекты не доходят). На клиенте `bind` подписывается
	  на `room.onMessage`: кадр с этим именем декодируется в аргументы и
	  тело исполняется локально.

	Ограничения: public, не static, без optional-аргументов, с явным
	типом возврата; один режим на метод. В теле доступны `state`
	(сервер — документ скрипта; клиент — последний снапшот) и `caller`
	(session_id вызвавшего; только server-режим). `SyncBuilder`
	генерирует `messages()` (имена server-методов), `call`/`reply`
	(если не заданы вручную), стабы и — при наличии clients-методов —
	клиентский диспетчер событий.

	Серверные хуки (опционально): `onJoin(sid, auth)`, `onLeave(sid,
	reason)` — вернуть эффекты или null.
**/
@:autoBuild(gamessa.script.SyncBuilder.build())
class Sync<TState> extends ServerLogic<TState>
{
	#if lua
	/** Клиентский канал комнаты (после `bind`). На lua-чанке не типизируется
		Room'ом, чтобы не тянуть клиентский транспорт в серверный чанк. */
	public var room(default, null):Dynamic;
	#else
	public var room(default, null):gamessa.Room<TState>;
	#end

	/** Сервер: session_id вызвавшего (заполняет сгенерированный диспетчер). */
	public var caller(default, set):Null<String>;

	/** Сервер: текущий документ состояния (заполняет сгенерированный диспетчер). */
	public var state(default, set):Null<TState>;

	function set_caller(v:Null<String>):Null<String>
		return caller = v;

	function set_state(v:Null<TState>):Null<TState>
		return state = v;

	public function new()
	{
		super();
	}

	/**
		Клиент: привязать канал комнаты — стабы @:rpc шлют через него,
		`state` держит последний снапшот (onStateChange). Наследники с
		clients-методами получают переопределение с подпиской на
		`room.onMessage` (диспетчеризация типизированных событий).
	**/
	#if lua
	public function bind(room:Dynamic):Void
	#else
	public function bind(room:gamessa.Room<TState>):Void
	#end
	{
		this.room = room;
		#if !lua
		room.onStateChange.add(s -> state = s);
		#end
	}

	/** Серверный хук: клиент присоединился. Вернуть эффекты (или null). */
	function onJoin(_sid:String, _auth:Dynamic):Array<Effect>
		return null;

	/** Серверный хук: клиент ушёл. Вернуть эффекты (или null). */
	function onLeave(_sid:String, _reason:String):Array<Effect>
		return null;
}
