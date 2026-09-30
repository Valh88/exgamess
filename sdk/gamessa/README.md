# Gamessa

**Haxe-клиентский SDK для [ExGames](../../../README.md)** — master-server
фреймворка на Elixir/Phoenix. HTTP (auth + matchmake) и WebSocket-канал
комнат с бинарным протоколом `[opcode u8][msgpack]`, авто-reconnect и
платформенными абстракциями транспорта/HTTP/хранилища.

Платформы: **JS** (браузер/node) и **HashLink** — готово; cpp/neko — тот же
sys-путь, что и HL. Остальные таргеты добавляются реализацией трёх
интерфейсов (см. «Платформы»).

## Установка

```bash
haxelib git hxWebSockets https://github.com/ncannasse/hxWebSockets
# затем скопируйте/подключите репозиторий как local haxelib:
haxelib local gamessa sdk/gamessa.zip   # либо добавьте -cp path/to/sdk/gamessa/source
```

Зависимости: `hxWebSockets` (транспорт), `utest` (только тесты).

## Быстрый старт

```haxe
import gamessa.Client;
import gamessa.Room;

var client = new Client("http://localhost:4100");

client.register("ann", "secret123", auth -> {
    client.joinOrCreate("chat", {channel: "global"}, reservation -> {
        var room = client.connectRoom(reservation);

        room.onJoin.add(e -> room.send("say", {text: "hello!"}));
        room.onMessage.add(e -> trace('msg ${e.type}: ${e.message}'));
        room.onStateChange.add(state -> trace("state: " + state));
        room.onDrop.add(_ -> trace("connection lost, reconnecting…"));
        room.onError.add(e -> trace('error ${e.code}: ${e.message}'));
        room.onLeave.add(e -> trace('left (${e.code})'));
    }, err -> trace(err));
}, err -> trace(err));
```

Сервер для локальных экспериментов: `mix phx.server` в корне репозитория
(демо-комнаты `chat`, `arena`, `lobby`, `queue` регистрирует
`apps/arena_example`).

## API

### `gamessa.Client`

| метод | назначение |
|---|---|
| `register/login(username, password)` | auth; токен кэшируется и персистится в `storage` |
| `me()` | текущий пользователь |
| `restoreAuth()` | восстановить токен из storage при старте |
| `joinOrCreate/create/join(roomName, ?options)` | матчмейк (шаг 1) → `SeatReservation` |
| `joinById(roomId, ?options)` | join в конкретную комнату |
| `reconnect(roomId, token, ?sessionId)` | шаг 1 reconnect-флоу |
| `getAvailableRooms(?roomName)` | листинг комнат |
| `connectRoom(reservation)` | шаг 2: открыть WS-канал → `Room` |

Ошибки — `MatchMakeError` (протокольные коды 520–526 / HTTP).

TLS: конструктор — `new Client(endpoint, ?http, ?storage, verifyCert = true)`.
Для dev-стенда с самоподписанным сертификатом передайте `verifyCert = false` —
проверка отключается и для HTTP (дефолтный `SysHttpClient`), и для WS-комнат
(`WebSocketTransport`); на hl/cpp/neko, js сертификат проверяет браузер.
Эндпоинт `https://…` сам выводит `wss`/`https` во все соединения.

### `gamessa.Room`

Сигналы: `onJoin`, `onMessage`, `onStateChange`, `onError`, `onDrop`,
`onLeave` (`gamessa.util.Signal<T>`, `add()` возвращает функцию отписки).

Состояние типизируется параметром `Room<S>` — typedef от wire-структуры
состояния комнаты (анонимные объекты; динамические ключи map'ов — `Dynamic`):

```haxe
typedef ArenaState = {var mode(default, never):String; var tick(default, never):Int;
    var players(default, never):Dynamic; var scores(default, never):Dynamic;}

var room:Room<ArenaState> = client.connectRoom(reservation);
room.onStateChange.add(s -> trace('mode=${s.mode} tick=${s.tick}'));
```

Без аннотации состояние динамическое. Генерики стираются — типизация
compile-time, сервер структуру не валидирует.

| метод | назначение |
|---|---|
| `send(type, payload)` | сообщение (до JOIN буферизуется, cap `bufferLimit`) |
| `request(type, payload, ?timeout)` | запрос-ответ по `request_id` (таймаут по умолчанию 10с) |
| `ping(cb, err)` | RTT-замер (попутно синхронизирует время) |
| `serverNow()` | оценка серверного времени, unix-ms (см. ниже) |
| `timeSynced()` | true, когда offset подтверждён серверным PONG'ом |
| `leave(?consented)` | покинуть комнату (кадр `LEAVE_ROOM`) |

Свойства reconnect: `reconnectDelayMs` (100), `reconnectMaxDelayMs` (5000),
`maxRetries` (15) — экспоненциальный backoff **после обрыва** (сам по себе
reconnect не периодический); после исчерпания — `onLeave` с кодом 4003.
Токен ротируется сервером при каждом переподключении и обновляется в
`room.reconnectionToken`.

Keepalive: `keepAliveMs` (25с, 0 — выключить). Сервер закрывает WS, если от
клиента нет данных 60с (`timeout` в `WsController`), поэтому SDK сама шлёт
PING — соединение не рвётся во время простоя. Держите интервал меньше
серверного таймаута и таймаутов NAT/прокси.

Серверное время: PING несёт метку `{t}`, сервер эхирует её со своим штампом
`{t, ts: unix-ms}`; из замеров EMA-оценка смещения часов:

```haxe
room.serverNow()   // ≈ unix-ms сервера, точность порядка RTT/2
```

Синхронизация уходит сразу после join и обновляется на каждом
keepalive-PING; до первого PONG `serverNow()` возвращает локальные часы
(проверяйте `timeSynced()`). Годится для серверных дедлайнов, передаваемых
как unix-ms.

Каждый ping-кадр после первого замера несёт и измеренный RTT
(`{"t": …, "rtt": ms}`) — сервер хранит его в клиенте со сглаживанием
(читается из игровой логики `Room.client_rtt/2`; цифра клиент-отчётная —
для мониторинга и лаг-осознанной логики, не для античита).

### Reconnect-флоу

1. Обрыв транспорта (без кадра `LEAVE_ROOM`) → `onDrop`, комната сервера
   держит место `reconnect_ttl` (30с по умолчанию);
2. SDK: `POST /api/matchmake/reconnect/:room_id` → WS
   `/ws/:room_id?sessionId=…&reconnectionToken=…` → `JOIN_ROOM` с новым
   токеном + полный снапшот `ROOM_STATE`;
3. исчерпание попыток → `onLeave(4003)`.

Окончательный отказ сервера (комната/токен не существуют: 520/521/522 —
например, сервер перезапустили) завершает reconnect **сразу**, без ретраев:
`onLeave(4003, "reconnect rejected: …")`. Ретраи с backoff — только для
временных сбоев (сеть недоступна, 5xx).

### Очередь подбора (`queue`)

Демо-очередь (из `apps/arena_example`): игрок встаёт в очередь, сервер
группирует по рангу и рассылает `{"seat": {room_id, session_id, rank}}` —
по нему клиент подключается к матч-комнате:

```haxe
client.joinOrCreate("queue", {}, res -> {
    var queue = client.connectRoom(res);

    queue.onMessage.add(e -> {
        if (e.type != "seat")
            return;
        var s:StringMap<Dynamic> = e.message;
        var match = client.connectRoom(new SeatReservation(s.room_id, s.session_id));
        match.onJoin.add(_ -> trace("in match!"));
    });
}, err -> trace(err));
```

Ранг берётся **с сервера** (рейтинги Elo аккаунтов, ключ `game` — тип
матч-комнаты; стартовый — 1000). Клиентский `"rank"` в опциях применяется
только если серверный источник рангов не настроен (`:rank_source`).

### `gamessa.script.Sync` — типизированные @:rpc (общий класс клиента и сервера)

`Sync<TState>` — наследник серверного `ServerLogic` (см.
`doc/LUA_SCRIPTING.md`, «Sync»), где методы комнаты объявляются
атрибутом `@:rpc`. Один и тот же класс компилируется и в Lua-чанк
сервера (`-D gamessa-server`, тела выполняются), и в клиентскую
сборку — где имена становятся типизированными стабами:

```haxe
class ChatSync extends gamessa.script.Sync<ChatState> {
  // клиент → сервер, fire-and-forget (возврат Void | Array<Effect>)
  @:rpc public function say(text:String):Array<Effect> { ... }

  // клиент → сервер, ответ значением (любой иной возврат)
  @:rpc public function seq():Int { ... }

  // сервер → клиенты, типизированное событие (только Void; тело
  // исполняется на клиенте при кадре "userCount")
  @:rpc(clients) public function userCount(count:Int):Void { ... }
}

var chat = new ChatSync();
chat.bind(room);          // стабы шлют через room; state ← снапшоты
chat.say("привет");       // → room.send("say", …)
chat.seq(v -> trace(v));  // → room.request("seq", …)
```

Направление задаёт режим атрибута: `@:rpc` / `@:rpc(server)` — клиент
→ сервер (умолчание), `@:rpc(clients)` — сервер → клиенты. На сервере
в теле доступны `state` (документ состояния) и `caller` (session_id
вызвавшего); серверные хуки `onJoin(sid, auth)` / `onLeave(sid,
reason)` возвращают эффекты. Ограничения: public, не static, без
optional-аргументов, с явным типом возврата; один режим на метод;
иные режимы — ошибка компиляции. `bind()` синхронизирует `state` со
снапшотами (`onStateChange`) и подписывает клиент на события
`@:rpc(clients)`.

## Потоки и Dispatcher

Весь API SDK неблокирующий на всех платформах: WS-подключение (включая
TCP-коннект на sys-таргетах), HTTP и чтение сокета идут в фоновых потоках;
connect-таймаут настраивается (`transport.connectTimeoutMs`, 10с по
умолчанию). Неудача подключения приходит в `onError`/`onClose` и
обрабатывается `Room` как обрыв (auto-reconnect).

На sys-таргетах (HL/cpp/neko) транспорт и HTTP доставляют события из
фоновых потоков. Чтобы маршалировать колбэки в поток приложения
(игровой цикл Heaps и т.п.), задайте один раз:

```haxe
gamessa.util.Dispatcher.post = f -> mainThreadQueue.push(f);
```

По умолчанию колбэки вызываются из потока доставки (JS — однопоточно).

## Платформы

| слой | JS | HashLink | остальныe sys |
|---|---|---|---|
| транспорт | `hx.ws.WebSocket` (js.html.WebSocket) | hxWebSockets (sys-сокеты, поток чтения) | то же |
| HTTP | `FetchHttpClient` (window.fetch) | `SysHttpClient` (HTTP/1.1, поток) | то же |
| storage | `JsStorage` (localStorage) | `FileStorage` (JSON-файл) | то же |

Свои реализации — интерфейсы `gamessa.transport.ITransport`,
`gamessa.http.IHttpClient`, `gamessa.storage.IStorage` (например, передайте
транспорт в `client.connectRoom(reservation, myTransport)`). HTTPS в
`SysHttpClient` — через `sys.ssl.Socket` (HL/cpp/neko).

**Заметка про HL:** в стдлибе Haxe (`std/hl/_std/sys/net/Socket.hx`)
`Socket.select` использует общий статический буфер без блокировки — при
нескольких WS-сокетах в одном процессе (auto-reconnect, очередь+матч)
возникают гонки и спонтанные обрывы. Применён локальный патч стдлибы
(мьютекс вокруг select; см. историю репозитория). При обновлении Haxe
через scoop патч слетает — symptoms: спонтанные `connection lost` через
несколько секунд при 2+ сокетах.

## Разработка

```bash
haxe test.hxml               # юнит-тесты кодека/кадров/времени/лага (190 проверок, interp)
haxe test_integration.hxml   # против живого сервера PORT=4100 (graceful-skip)
haxe build.hxml -js bin/gamessa.js        # проверка компиляции JS
haxe build.hxml -hl bin/gamessa.hl        # проверка компиляции HL
haxe example.hxml && neko bin/example.n   # чат-пример
```

Интеграционные тесты требуют запущенного сервера
(`PORT=4100 mix phx.server` в корне) и `hl` в PATH; без сервера —
пропускаются. Под node: соберите `RunIntegration` c `-js`.
Альтернативный стенд задаётся через `GAMESSA_ENDPOINT`, например TLS-сервер:
`GAMESSA_ENDPOINT=https://localhost:4001 haxe test_integration.hxml`
(раннер сам передаёт `verifyCert = false` в `Client` — отключение проверки
самоподписанного сертификата и на WS, и на HTTP; на js сертификат проверяет
браузер).

### Имитация лагов (dev)

`gamessa.debug.LatencyTransport` — обёртка над транспортом с задержкой,
джиттером и потерей кадров (аналог `latencySimulation` в Colyseus).
Подставляется точкой `connectRoom`, так что лаги действуют с первого кадра:

```haxe
import gamessa.debug.LatencyTransport;

var room = client.connectRoom(res,
    LatencyTransport.wrapWebSocket(client, res, {delay: 150, jitter: 40}));
// вариант: {delay: 100, dropRate: 0.05} — потери исходящих кадров
```

Только для разработки/тестов; при auto-reconnect Room создаёт транспорт сам,
без обёртки.

## Протокол

Полная спецификация — `doc/PROTOCOL.md` в корне репозитория. Кадры:
`[opcode u8][msgpack]`; опкоды совместимы с Colyseus (JOIN_ROOM=10 …
ROOM_RESPONSE=22).
