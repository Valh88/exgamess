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

### `gamessa.Room`

Сигналы: `onJoin`, `onMessage`, `onStateChange`, `onError`, `onDrop`,
`onLeave` (`gamessa.util.Signal<T>`, `add()` возвращает функцию отписки).

| метод | назначение |
|---|---|
| `send(type, payload)` | сообщение (до JOIN буферизуется, cap `bufferLimit`) |
| `request(type, payload, ?timeout)` | запрос-ответ по `request_id` (таймаут по умолчанию 10с) |
| `ping(cb, err)` | RTT-замер |
| `leave(?consented)` | покинуть комнату (кадр `LEAVE_ROOM`) |

Свойства reconnect: `reconnectDelayMs` (100), `reconnectMaxDelayMs` (5000),
`maxRetries` (15) — экспоненциальный backoff **после обрыва** (сам по себе
reconnect не периодический); после исчерпания — `onLeave` с кодом 4003.
Токен ротируется сервером при каждом переподключении (как в Colyseus) и
обновляется в `room.reconnectionToken`.

Keepalive: `keepAliveMs` (25с, 0 — выключить). Сервер закрывает WS, если от
клиента нет данных 60с (`timeout` в `WsController`), поэтому SDK сама шлёт
PING — соединение не рвётся во время простоя. Держите интервал меньше
серверного таймаута и таймаутов NAT/прокси.

### Reconnect-флоу

1. Обрыв транспорта (без кадра `LEAVE_ROOM`) → `onDrop`, комната сервера
   держит место `reconnect_ttl` (30с по умолчанию);
2. SDK: `POST /api/matchmake/reconnect/:room_id` → WS
   `/ws/:room_id?sessionId=…&reconnectionToken=…` → `JOIN_ROOM` с новым
   токеном + полный снапшот `ROOM_STATE`;
3. исчерпание попыток → `onLeave(4003)`.

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

## Разработка

```bash
haxe test.hxml               # юнит-тесты кодека/кадров (108 проверок, interp)
haxe test_integration.hxml   # против живого сервера PORT=4100 (graceful-skip)
haxe build.hxml -js bin/gamessa.js        # проверка компиляции JS
haxe build.hxml -hl bin/gamessa.hl        # проверка компиляции HL
haxe example.hxml && neko bin/example.n   # чат-пример
```

Интеграционные тесты требуют запущенного сервера
(`PORT=4100 mix phx.server` в корне) и `hl` в PATH; без сервера —
пропускаются. Под node: соберите `RunIntegration` c `-js`.

## Протокол

Полная спецификация — `doc/PROTOCOL.md` в корне репозитория. Кадры:
`[opcode u8][msgpack]`; опкоды совместимы с Colyseus (JOIN_ROOM=10 …
ROOM_RESPONSE=22).
