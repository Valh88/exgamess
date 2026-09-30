# Поиск игры (матчмейкинг): использование и устройство

Как игроки находят игру: REST-брони, комнаты-очереди, серверные рейтинги
(Elo) и WebSocket-подключение к матчу. Протокол кадров — `doc/PROTOCOL.md`,
архитектура — `doc/ARCHITECTURE.md`.

---

## 1. Модель: двухфазный вход

Как в Colyseus, вход в игру — два шага:

```
1. HTTP:  POST /api/matchmake/…  →  бронь места (room_id + session_id, TTL 15с)
2. WS:    /ws/:room_id?sessionId=…  →  кадр JOIN_ROOM → игра
```

Бронь «держит» место 15 секунд; если клиент не подключился — место
освобождается. Пока сессия не подключена, она всё равно учитывается в
заполненности комнаты (гонок броней нет — всё сериализует GenServer
матчмейкера).

### Прямой вход в игру (curl)

```bash
# 1. регистрация/вход → токен
curl -s -X POST localhost:4100/api/auth/register \
  -H 'content-type: application/json' \
  -d '{"username":"ann","password":"secret123"}'
# => {"token":"...","user":{...}}

# 2. бронь: найти подходящую комнату или создать
curl -s -X POST localhost:4100/api/matchmake/join_or_create/arena \
  -H 'authorization: Bearer <TOKEN>' -H 'content-type: application/json' \
  -d '{"options":{"mode":"ranked"}}'
# => {"room_name":"arena","room_id":"Ab3xYz9Kp","session_id":"sKd83jdDk2m1"}

# 3. WebSocket к матчу
# ws://localhost:4100/ws/Ab3xYz9Kp?sessionId=sKd83jdDk2m1
```

### Методы матчмейкинга

| метод | поведение |
|---|---|
| `join_or_create/:room_name` | найти свободную комнату типа, иначе создать |
| `create/:room_name` | всегда новая комната |
| `join/:room_name` | только существующая (иначе `404/521`) |
| `join_by_id/:room_id` | бронь в конкретной комнате |
| `reconnect/:room_id` | возврат в живую сессию после обрыва (см. ниже) |

Опции `{"options": {...}}` участвуют в поиске (поля типа из `filter_by`)
и уходят в комнату; ответ — seat reservation JSON. Ошибки: `520` (тип не
зарегистрирован), `521` (нет комнаты), `522` (комнаты нет), `523`
(заполнена), `423` (закрыта), `401` (нет/неверен токен).

---

## 2. Очередь подбора: игрок → группа → матч

Комната-очередь (`ExGames.Rooms.QueueRoom`) — тонкая оболочка; вся логика
подбора — во встраиваемом модуле `ExGames.Matchmaking.PairsByRank`
(`ExGames.Room.Logic`), как правила арены в `ArenaExample.Rules`.

### Как пользоваться (Haxe, gamessa)

```haxe
// 1. встать в очередь (обычный join комнаты "queue")
client.joinOrCreate("queue", {}, res -> {
    var queue = client.connectRoom(res);

    // 2. ждать рассадки
    queue.onMessage.add(e -> {
        if (e.type != "seat") return;

        // {"seat": {room_id, session_id, rank}}
        var s:StringMap<Dynamic> = e.message;

        // 3. подключиться к матчу по выданному месту
        var match = client.connectRoom(new SeatReservation(s.room_id, s.session_id));
        match.onJoin.add(_ -> trace("in match!"));
    });
}, err -> trace(err));
```

### Как это работает внутри

1. `logic_join` — игрок попадает в пул ожидания (session_id, ранг,
   время входа); всем рассылается `"queue_join"`.
2. `logic_tick` (раз в `patch_rate`, у очереди 1с) — группировка:
   сортировка по рангу → скользящее окно `group_size` → если разброс
   рангов в окне ≤ `max_rank_gap`, группа собрана. Игрок, ожидавший дольше
   `priority_after_ms`, рассматривается первым и гэп для его группы
   не применяется.
3. Для каждой собранной группы: `Matchmaker.create` (новая матч-комната) →
   `reserve_seat` каждому участнику → каждому лично уходит сообщение
   `"seat"` → клиент подключается к матчу (шаг 2 двухфазного входа).

### Опции комнаты очереди

| опция | по умолчанию | смысл |
|---|---|---|
| `"match_room_name"` | — (обязательна) | тип матч-комнаты |
| `"group_size"` | `2` | размер группы |
| `"max_rank_gap"` | `200` | допустимый разброс рангов в группе |
| `"priority_after_ms"` | `10_000` | ожидание до приоритета |

Своя стратегия подбора = свой модуль `ExGames.Room.Logic`
(`logic_join` ставит в очередь, `logic_tick` собирает матчи) и своя
оболочка `logic: [MyMatchmaking]`. Список `logic:` — не конвейер над
общим пулом: у каждого модуля свой срез состояния, поэтому стратегия
подбора в комнате одна.

---

## 3. Рейтинги (Elo)

### Где хранится

БД аккаунтов (та же SQLite, FK на `users`):

* `ex_games_ratings` — `user_id, game, rating, wins, losses, draws`
  (уникальность `[user_id, game]`);
* `ex_games_matches` — история: игра + исходы участников.

API (`ExGames.Account`):

```elixir
Account.get_rating(user_id, "arena")   # {:ok, 1016} | :error
Account.record_match("arena", %{1 => :win, 2 => :loss, 3 => :draw})
# => {:ok, %{1 => 1016, 2 => 984, 3 => 1000}}
```

Пересчёт — Elo, `K = 32`, «каждый против каждого»:
`new = old + K/(n−1) · Σ(S − E)`, где `S` — исход (1 / 0.5 / 0),
`E = 1 / (1 + 10^((R_opp − R_own) / 400))`. Стартовый рейтинг — **1000**.
Матч с неизвестным `user_id` откатывается целиком.

### Откуда очередь берёт ранг (приоритет источников)

```
auth-ранг (доверенный, проставлен сервером)
  → RankSource.rating(user_id, game)   # серверное хранилище
    → клиентский ранг из опций          # только если источник НЕ настроен
      → 1000                            # базовый
```

Если `rank_source` настроен — клиентский ранг из опций **игнорируется**
(новому игроку выдаётся базовый 1000): клиент не может повлиять на свой
ранг. Ключ `game` — тип матч-комнаты: очередь передаёт его в матч
(`{"game": match_room_name}`), а запись результата использует тот же
ключ — чтение и запись всегда согласованы.

### Запись результата

Референс — демо-арена (`ArenaExample.Rules`): при достижении
`@win_score` (5 очков) рассылается `"game_over"`, в рейтинги уходит
`record_match(game, %{winner => :win, остальные => :loss})`, комната
останавливается. Игроки без `user_id` в рейтинг не попадают.

### Конфигурация источника рангов

```elixir
# включено (по умолчанию в umbrella): рейтинги Elo аккаунтов
config :ex_games, :rank_source, ExGames.Account.RankSource

# выключить (ранг только из клиентских опций):
# удалить строку — ядро не знает ничего о БД
```

Ядро объявляет только поведение `ExGames.Matchmaking.RankSource`
(`rating(user_id, game) :: {:ok, rank} | :error`); хранилище и Elo живут
в `ex_games_account`. Своё хранилище = свой модуль с этим поведением.

---

## 4. Reconnect после обрыва

Обрыв без кадра `LEAVE_ROOM` не удаляет игрока: комната держит сессию в
слоте reconnection `reconnect_ttl` (30с по умолчанию). Клиент:

1. `POST /api/matchmake/reconnect/:room_id` —
   `{"session_id": "…", "reconnection_token": "…"}` → `session_id`
   (токен самодостаточен, `session_id` можно опустить);
2. `WS /ws/:room_id?sessionId=…&reconnectionToken=…` → `JOIN_ROOM`
   с **новым** токеном (ротация как в Colyseus) + полный снапшот
   `ROOM_STATE`. Логики повторный join не получают.

Исчерпание попыток → `onLeave(4003)`. Окончательный отказ
(комната/токен исчезли — например, рестарт сервера) → сразу
`onLeave(4003, "reconnect rejected")` без ретраев. Для клиентов gamessa
весь цикл автоматический (`Room.onDrop` → reconnect → `onJoin`); детали —
`sdk/gamessa/README.md`.

---

## 5. Листинг комнат (внутри)

«Таблицы матчмейкинга» в БД нет — и у Colyseus её нет: листинг живых
комнат — это эфемерное состояние. У Colyseus это driver (`LocalDriver` —
массив в памяти; Redis/Mongo — только для multi-node); у нас — ETS-таблица
`:ex_games_matchmaker_rooms` под управлением `Matchmaker`:

* запись создаётся при создании комнаты, `clients` обновляется на
  join/leave, удаляется при закрытии комнаты и по монитору при её падении;
* поиск (`pick_room`): `room_name` совпадает → не `locked` → есть места →
  совпадают `filter_by`-опции → **наименее заполненная первой**;
* типы комнат регистрируются при старте приложения
  (`Matchmaker.define_room/3`, см. Boot демо-приложения).

Листинг просматривается через `GET /api/rooms[?room_name=…]` и PubSub-топик
лобби (`ExGames.Matchmaker.lobby_topic()`).

---

## 6. Расширение

* **Своя стратегия подбора** — модуль `ExGames.Room.Logic` + оболочка
  `logic: [MyMatchmaking]` (можно без очереди: любые `logic_tick`-политики).
* **Свой источник рангов** — поведение `ExGames.Matchmaking.RankSource`
  + одна строка конфига.
* **Своя политика выбора комнаты** (sortBy и т.п.) — разворот `pick_room`
  в подключаемую стратегию матчмейкера; пока фиксировано «наименее
  заполненная первой».
