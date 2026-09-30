# ARCHITECTURE — архитектура ExGames

Umbrella из четырёх приложений; границы принуждены компилятором: ядро
`ex_games` не знает ни о Phoenix-вебе, ни о БД, ни о конкретных играх.

```
┌──────────────────────────────────────────────────────────────┐
│ arena_example (игра)      Boot: define_room + системные      │
│                           комнаты. Комнаты на публичном API. │
├──────────────────────────────────────────────────────────────┤
│ ex_games_web (транспорт)  REST (auth/matchmake/rooms/admin)  │
│                           WS /ws/:room_id → RoomSocket       │
│                           Plugs: Auth (Bearer), RequireRole, │
│                           CORS. LiveView-заготовка админки.  │
├──────────────────────────────────────────────────────────────┤
│ ex_games_account (данные) Ecto/SQLite: users, roles, bans.   │
│                           Token behaviour (HMAC по умолч.)   │
├──────────────────────────────────────────────────────────────┤
│ ex_games (ядро)           Room DSL/Server, Matchmaker,       │
│                           Presence, Chat/Lobby/Queue,        │
│                           Wire (кодек), GameLogic (адаптеры) │
└──────────────────────────────────────────────────────────────┘
```

## Supervision tree ядра (`ex_games`)

Стратегия `rest_for_one` (порядок = зависимости):

```
ExGames.Supervisor (rest_for_one)
├── Phoenix.PubSub (ExGames.PubSub)      события лобби/presence/чат-шина
├── Registry (ExGames.RoomRegistry)      room_id → pid
├── Registry (ExGames.LogicRegistry)     logic_id → pid
├── DynamicSupervisor (RoomSupervisor)   комнаты, restart: :temporary
├── DynamicSupervisor (LogicSupervisor)  нативная логика, restart: :transient
├── ExGames.Matchmaker (GenServer)       ETS-листинги, брони, мониторы комнат
└── ExGames.Presence (Phoenix.Tracker)   онлайн-статусы
```

* Комнаты — `:temporary`: упавшая комната не рестартует (игровое состояние
  невосстановимо), матчмейкер чистит её листинг по `{:ex_games, :lobby, {:remove, _}}`
  и по собственному `Process.monitor` (DOWN).
* Логика — `:transient`: падение нативного процесса перезапускает адаптер,
  состояние игры принадлежит комнате, а не логике.

## Двухфазный join (как в Colyseus)

```
Клиент                         HTTP            Matchmaker          Room
  │  POST /api/matchmake/…  ──►                 │                  │
  │                          define/поиск       │                  │
  │                          reserve_seat ───────────────────────► │  (бронь, TTL 15с)
  │  ◄── {room_id, session_id}                 │                  │
  │  GET /ws/:room_id?sessionId=…  ──► RoomSocket ── attach ────► │
  │  ◄── JOIN_ROOM(10), ROOM_STATE(14)          │   handle_join    │
  │  ◄► ROOM_DATA(13) / REQUEST(21)/RESPONSE(22)│                  │
```

Гонка параллельных `join_or_create` исключена: поиск + создание комнаты
выполняются внутри GenServer матчмейкера. Листинг комнат живёт в ETS
(`:ex_games_matchmaker_rooms`), публикуется самой комнатой при каждом
изменении (join/leave/бронь/lock/metadata) — без self-call; события идут
в PubSub-топик `ex_games:lobby`, откуда их читает LobbyRoom (снапшот +
дельты `room_add`/`room_update`/`room_remove`).

## Комната (`ExGames.Room`)

* **DSL**: `use ExGames.Room, max_clients: …, patch_rate: …` + макросы
  `message`/`request` (клавзы с паттерн-матчингом payload'а; module
  attributes + `@before_compile`). Реализация хранения клавз — через
  `@attr`-синтаксис (не `Module.put_attribute` из макроса: значения,
  записанные так, не доживают до `__before_compile__` на Elixir 1.19).
* **Server** (GenServer): брони с TTL, мониторы транспортов, rate-limit
  (кадров/с), тик `patch_rate`, авто-диспоуз пустой комнаты, безопасные
  колбэки (исключение в клавзе не роняет комнату).
* **Эффекты**: `broadcast/3`, `send_to/4`, `kick/2`, `lock/unlock`,
  `set_metadata/2`, `set_state/2`, `clients/1`, `count/1` — все через
  Registry, можно вызывать и извне комнаты.
* **Состояние**: полный снапшот `ROOM_STATE` при изменении (`set_state` +
  dirty-флаг на тике); дельты — слот `ROOM_STATE_PATCH` (код 15) для
  будущей версии.

## Встраиваемая логика (`ExGames.Room.Logic`)

Логика игры отделяется от оболочки комнаты — по образу Colyseus, но как
обычные Elixir-модули (без внешних скриптов):

```
ArenaRoom (оболочка: use ExGames.Room, logic: [Rules])
└── Rules (use ExGames.Room.Logic)
      ├── logic_init/auth/join/leave/tick/terminate
      ├── message "move" … / message "hit" …   ← тот же DSL
      └── свой срез состояния (хранится в процессе комнаты)
```

* **Диспетчеризация сообщений** — по объявленным типам (`__message_types__/0`
  генерируется из клавз `message`): кадр уходит в первый встроенный модуль,
  объявивший тип; иначе — в саму комнату; иначе игнор. Аналог реестра
  `onMessage` в Colyseus.
* **События join/leave/tick/info/terminate** — цепочкой через все модули в
  порядке объявления; `{:stop, reason, state}` любого модуля останавливает
  комнату/отклоняет join. `logic_info/2` получает любые не-служебные
  сообщения ящика процесса комнаты — PubSub-подписки, пуши от внешних
  процессов (логика подписывается в `logic_init`)
* **Авторизация** — цепочка на брони места: `handle_auth` комнаты, затем
  `logic_auth` модулей; можно преобразовывать auth-данные и отклонять.
* **Изоляция**: исключение в клавзе модуля не роняет комнату; срез
  состояния каждого модуля обновляется независимо.

Модуль логики — чистый Elixir-модуль: юнит-тесты без комнаты,
переиспользование между комнатами; та же форма контракта позже
отображается на `ExGames.GameLogic` (вынос вычислений в нативный процесс
через Port/TCP-адаптер без изменения комнаты).

### Подключаемые стратегии подбора

Тот же контракт работает и для матчмейкинга: вся логика подбора игроков
в матчи живёт в `ExGames.Room.Logic`-модуле, встроенном в комнату-очередь:

```
QueueRoom (оболочка: use ExGames.Room, logic: [PairsByRank])
└── ExGames.Matchmaking.PairsByRank (use ExGames.Room.Logic)
      ├── logic_join/leave — вход/выход из очереди (пул waiting в своём срезе)
      └── logic_tick — группировка по рангу → Matchmaker.create → брони → "seat"
```

Своя стратегия подбора = своя оболочка с `logic: [MyMatchmaking]`.
Встроенный `Matchmaker` при этом остаётся инфраструктурным GenServer
(реестр типов, листинг в ETS, брони) — без клиентского контракта комнаты.
Модули в `logic:` — независимые срезы с одними событиями, а не конвейер
`|>` над общим пулом: стратегия подбора в очереди — одна.

### Серверные ранги (`RankSource`)

Стратегии подбора могут брать ранг из серверного хранилища: ядро
объявляет поведение `ExGames.Matchmaking.RankSource`
(`rating(user_id, game) :: {:ok, rank} | :error`), реализация живёт
в приложении-композиции и выбирается конфигом:

    config :ex_games, :rank_source, ExGames.Account.RankSource

Референс — рейтинги Elo (K=32) в `ex_games_account`
(`Account.get_rating/2`, `Account.record_match/2`; таблицы
`ex_games_ratings`/`ex_games_matches` в общей БД, FK на `users`).
Приоритет ранга в `PairsByRank`: auth (доверенный) → RankSource →
клиентские опции → 1000. Очередь передаёт тип матч-комнаты ключом
`"game"` — запись результата (`record_match/2`) и чтение ранга
используют один и тот же ключ.


### Дельта-синхронизация состояния

По механике референса (Colyseus): комната опционально шлёт состояние
дельтами. Режим — опция комнаты `state_sync: :snapshot | :delta`
(по умолчанию `:snapshot`):

```
первая доставка      → ROOM_STATE  (полный снапшот)
изменённый тик       → diff(last_sent, current) → ROOM_STATE_PATCH
  пустой дифф        → кадр не отправляется
новый клиент/reattach→ флаш диффа текущим клиентам + полный снапшот новичку
reconnect            → полный ROOM_STATE (resync)
```

Дифф — структурный, msgpack: список операций «путь → значение» /
«путь → удалить» (`ExGames.Room.StateDiff` на сервере,
`gamessa.StatePatch` на клиенте); операции-присваивания идемпотентны.
Подробно — [DELTA_SYNC.md](DELTA_SYNC.md); формат кадров —
[PROTOCOL.md](PROTOCOL.md); сквозной пример — демо-арена
(`state_sync: :delta`).


## Presence

`ExGames.Presence` = `Phoenix.Tracker`: `track_user/untrack_user/list_online/
online?`. Автопочистка при смерти трекирующего процесса; события `:join`/
`:leave` бродкастятся в PubSub-топик `presence` (чат, лобби, админка).

## GameLogic (нативная логика)

`ExGames.GameLogic.Adapter` behaviour + адаптеры:

* `Adapters.Elixir` — in-process модуль;
* `Adapters.Port` — внешний процесс по stdio (`{:packet, 4}`);
* `Adapters.TCP` — тот же фрейминг по `gen_tcp` (один бинарник работает
  обоими способами).

Фрейминг: `u32 length-prefix + msgpack`; состояние передаётся в каждом
запросе (см. PROTOCOL.md §3). Новый транспорт (NIF/Rustler, distributed) —
новая реализация behaviour, ядро не меняется.

## Путь к multi-node

V1 — один узел, но решения кластер-френдли:

* PubSub/Presence/лобби-события — через `Phoenix.PubSub` (заменяется
  на `Phoenix.PubSub.Redis` без правок кода);
* Registry — узловой; для кластера комнаты адресуются через глобальный
  реестр (`:global`, Horde.Registry) или через шардинг по узлам в
  матчмейкере (как в Colyseus: `processId` в reservation + RPC);
* ETS-листинги — узловые; в кластере их заменяет Redis/Postgres-драйвер
  (контракт — уже изолирован в `ExGames.Matchmaker`).

## Безопасность

* Пароли — Pbkdf2 (pure Elixir); токены — HMAC (`Plug.Crypto.sign`),
  TTL из конфига, поведение за `Token` behaviour (JWT заменяется одной
  реализацией).
* Комнаты могут переопределить `handle_auth/3` — вызывается при брони.
* Rate-limit сообщений, ограничение длины чат-сообщений, RBAC на
  админ-API (`RequireRole` plug).

## Плановое выключение (graceful shutdown)

Остановка ноды — через `ExGames.Runtime.Drain` (см. [DRAIN.md](DRAIN.md)):
хук `prep_stop/1` веб-приложения закрывает матчмейкер (`{:error, :draining}`
→ HTTP 503), рассылает живым комнатам закрытие 4001 «server shutdown» и ждёт
опустошения реестра (до `:drain_timeout_ms`). Пробы `/healthz` (liveness) и
`/readyz` (readiness) — для балансировщика и оркестратора.
