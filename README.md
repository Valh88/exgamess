# ExGames

Расширяемый **master-server фреймворк для онлайн-игр** на Elixir/OTP поверх
Phoenix 1.8: аккаунты и RBAC, матчмейкинг с двухфазным join, комнаты,
чат, лобби, очередь подбора, presence и мост к нативной игровой логике.
Референс архитектуры — [Colyseus](https://github.com/colyseus/colyseus).

Клиент — любой язык: фреймворк говорит по HTTP (JSON) + WebSocket
(бинарный протокол `[opcode u8][msgpack]`, совместимый по кодам операций
с Colyseus). Haxe-клиентский SDK — [`sdk/gamessa`](sdk/gamessa/README.md) (JS + HashLink, авто-reconnect).

## Структура (umbrella)

| приложение | назначение |
|---|---|
| `apps/ex_games` | ядро: комнаты, матчмейкер, presence, чат/лобби/очередь, протокол, GameLogic |
| `apps/ex_games_account` | аккаунты: пользователи, роли (RBAC), токены, баны (Ecto + SQLite) |
| `apps/ex_games_web` | Phoenix: REST API, WebSocket-транспорт, LiveView-заготовка админки |
| `apps/arena_example` | демо-игра: полный цикл от регистрации до матча 2×2 |
| `sdk/gamessa` | Haxe-клиентский SDK (JS + HashLink): msgpack, wire, Room, reconnect |

## Быстрый старт

```bash
mix setup          # deps + создать и замигрировать SQLite + сиды (admin)
mix phx.server     # http://localhost:4000
```

Smoke-прогон руками:

```bash
# 1. регистрация
curl -s -X POST localhost:4000/api/auth/register \
  -H 'content-type: application/json' \
  -d '{"username":"ann","password":"secret123"}'
# => {"token":"...","user":{...}}

# 2. матчмейкинг арены (шаг 1 двухфазного join)
curl -s -X POST localhost:4000/api/matchmake/join_or_create/arena \
  -H 'authorization: Bearer <TOKEN>' -H 'content-type: application/json' \
  -d '{"options":{"mode":"ranked"}}'
# => {"room_name":"arena","room_id":"...","session_id":"..."}

# 3. WebSocket (шаг 2): ws://localhost:4000/ws/<room_id>?sessionId=<session_id>
#    кадры: [opcode u8][msgpack] — см. doc/PROTOCOL.md
```

Админ после сидов: `admin / admin123123` (переопределяется env
`EX_GAMES_ADMIN_USERNAME/PASSWORD`), админ-API — `/api/admin/*`.

### TLS (https/wss в dev)

`mix phx.server` поднимает два листенера: **http://localhost:4000** и
**https://localhost:4001** (wss). TLS включён в `config/dev.exs` на
самоподписанном сертификате из `apps/ex_games_web/priv/cert/` (сгенерирован
`mix phx.gen.cert`; перегенерировать — запустить команду заново в
`apps/ex_games_web`). Используется `cipher_suite: :compatible` (TLS 1.2+1.3):
`:strong` — это только TLS 1.3, который нативные HL-клиенты (mbedtls) не умеют.

Клиенты:

- **Веб** — `Client` выводит `wss`/`https` из схемы эндпоинта: просто передайте
  `https://localhost:4001`. Браузер требует доверия к сертификату: один раз
  откройте `https://localhost:4001/healthz` и примите предупреждение.
- **Нативные (HL/cpp/neko)** — проверку self-signed сертификата отключает
  штатный выключатель std (до создания клиента; действует и на WS, и на HTTP):

  ```haxe
  #if (hl || cpp || neko)
  sys.ssl.Socket.DEFAULT_VERIFY_CERT = false; // только для dev-стенда!
  #end
  ```

  Точечная альтернатива — подкласс hxWebSockets `WebSocket` с override
  `createSocket()`, где `socket.verifyCert = false` для `wss` (см. README
  hxWebSockets). Для прода с сертификатом из доверенного CA ничего отключать
  не нужно; закрепить корневые CA можно через `sys.ssl.Socket.DEFAULT_CA`.

Код фреймворка и SDK менять не нужно: сервер просто предъявляет сертификат,
клиенты проверяют его средствами платформы.

## Тесты

```bash
mix test                        # все приложения (106 тестов)
mix test --include native      # + тесты Port-адаптера (spawn внешних процессов)
```

## API

### REST

| метод и путь | описание |
|---|---|
| `POST /api/auth/register` | регистрация → `{token, user}` |
| `POST /api/auth/login` | вход → `{token, user}` |
| `GET /api/me` | профиль (Bearer) |
| `POST /api/matchmake/:method/:room_name` | `join_or_create` \| `create` \| `join` → seat reservation |
| `GET /api/rooms[?room_name=]` | листинг комнат (для лобби) |
| `/api/admin/users…` | роли/баны (роль `admin`) |

### WebSocket

`GET /ws/:room_id?sessionId=:session_id` — после апгрейда клиент и сервер
обмениваются бинарными кадрами. Полная спецификация, включая формат кадров
и коды ошибок — [PROTOCOL.md](doc/PROTOCOL.md); архитектура и supervision tree —
[ARCHITECTURE.md](doc/ARCHITECTURE.md); поиск игры и рейтинги —
[MATCHMAKING.md](doc/MATCHMAKING.md); дельта-синхронизация состояния —
[DELTA_SYNC.md](doc/DELTA_SYNC.md); плановое выключение и пробы
healthz/readyz — [DRAIN.md](doc/DRAIN.md).

## Как писать игру

```elixir
defmodule MyGame.Arena do
  use ExGames.Room, max_clients: 8, patch_rate: 50

  @impl true
  def room_init(_options, _room), do: {:ok, %{players: %{}}}

  @impl true
  def handle_join(room, client, auth, state) do
    broadcast(room, "join", %{"session_id" => client.session_id})
    {:ok, put_in(state, [:players, client.session_id], 0)}
  end

  message "move", %{"x" => x}, room, client, state do
    broadcast(room, "moved", %{"who" => client.session_id, "x" => x})
    {:ok, put_in(state, [:players, client.session_id], x)}
  end
end

# регистрация в матчмейкере (в Boot вашего приложения)
ExGames.Matchmaker.define_room("arena", MyGame.Arena, filter_by: ["mode"])
```

Когда логики становится много, выносите её из оболочки комнаты во встраиваемые
модули `ExGames.Room.Logic` — тот же DSL, свой срез состояния, роутинг
сообщений по объявленным типам:

```elixir
defmodule MyGame.Rules do
  use ExGames.Room.Logic

  def logic_init(_options, _room), do: {:ok, %{scores: %{}}}

  message "hit", %{"target" => t}, room, client, state do
    broadcast(room, "hit", %{"by" => client.session_id, "target" => t})
    {:ok, update_in(state, [:scores, t], &(((&1 || 0) + 1)))}
  end
end

# оболочка подключает модуль строкой:
use ExGames.Room, max_clients: 8, logic: [MyGame.Rules]
```

Игровая логика может жить и в нативном процессе (C++/Rust/Haxe/Python —
что угодно): `ExGames.GameLogic` с адаптерами Port/TCP и одним фреймингом
(msgpack + u32 length-prefix). Краш нативного процесса не теряет игру —
состояние принадлежит комнате. Подробнее — `doc/ARCHITECTURE.md`.

## Конфигурация

БД — SQLite (`ecto_sqlite3`); переход на PostgreSQL — смена адаптера в
`ExGames.Account.Repo` и конфига, код не меняется. Прод-окружение
настраивается env-переменными (`PORT`, `SECRET_KEY_BASE`,
`EX_GAMES_WEB_DB_PATH`, `EX_GAMES_ADMIN_USERNAME/PASSWORD`) — см.
`config/runtime.exs`.
