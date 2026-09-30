# Данные: облачные сохранения и лидерборды

Персистентная периферия поверх игровой логики: где лежат таблицы, как
пользоваться REST и SDK. Состояние **активных** комнат по-прежнему живёт
только в памяти (как в Colyseus) — в БД хранится лишь игровая периферия.

## Принцип: узкие колонки + payload

Каждая таблица делит поля на два сорта:

- **Query-поверхность** — то, по чему сервер ищет/фильтрует/сортирует
  (`user_id`, `key`, `game`, `rating`, флаги) — отдельные типизированные
  колонки с индексами;
- **Payload** — содержимое, которое сервер хранит как есть и отдаёт
  целиком (`payload`, `results`) — одна колонка `:map` (JSON-текст в
  SQLite). Форму документа знает только игра: новые поля добавляются без
  миграций; если поле станет «горячим» — выносится в колонку или
  индексируется через SQLite JSON1 (`json_extract`) без смены схемы.

## Таблицы (общая БД `ex_games_account`)

| Таблица | Назначение | Payload |
|---|---|---|
| `users`, `roles`, `users_roles` | аккаунты, RBAC, баны | — |
| `ex_games_ratings` | Elo-рейтинг по игре (старт 1000) | — |
| `ex_games_matches` | история матчей | `results` (%{sid => исход}) |
| `ex_games_saves` | облачные сохранения | `payload` (непрозрачный JSON) |

Схема ядерных рейтингов/матчей задаётся контрактом `ExGames.Matchmaking.RankSource`;
новая таблица `ex_games_saves` — миграция `20260929073643_create_saves`
(unique index `[user_id, key]`, `on_delete: :delete_all` от пользователя).

## Cloud saves — REST

Все маршруты требуют Bearer-токен (scope `:require_auth`):

```
PUT    /api/saves/:key    {"payload": {...}}   → 200 {"key","payload","updated_at"}
GET    /api/saves/:key                         → 200 {"key","payload"}
GET    /api/saves                              → 200 {"saves":[{"key","updated_at"}]}
DELETE /api/saves/:key                         → 204 | 404
```

- Повторный `PUT` в тот же слот перезаписывает payload (upsert).
- `payload` — обязан быть JSON-объектом; иначе 400.
- Размер ограничен `config :ex_games_web, :save_max_bytes`
  (по умолчанию 256 KiB закодированного JSON) — 413 при превышении.
- Слоты изолированы по пользователю: чужой слот неотличим от отсутствующего (404).

### SDK (gamessa)

```haxe
client.saveData("world1", {level: 3, note: "привет"}, meta -> {...}, err -> ...);
client.getData("world1", payload -> trace(payload.level), err -> ...);
client.listSaves(saves -> ..., err -> ...);           // Array<SaveMeta>
client.deleteSave("world1", () -> ..., err -> ...);
```

`Client.saveData` использует `PUT` — в `IHttpClient` добавлен метод `put`
(реализован в `SysHttpClient` и `FetchHttpClient`; свои реализации
`IHttpClient` нужно дополнить).

## Лидерборды — REST

```
GET /api/leaderboard/:game?limit=50    → 200 {"game", "entries": [...]}
```

- Записи: `{"position", "user_id", "username", "rating", "wins", "losses", "draws"}`,
  позиции с 1; сортировка — рейтинг по убыванию, при равенстве меньший
  `user_id` выше (детерминированный tie-break).
- `limit` — 1..100 (по умолчанию 50).
- Игрок попадает в таблицу после первого матча (`Account.record_match/2`
  вызывается игровой логикой комнаты — см. MATCHMAKING.md).

SDK:

```haxe
client.getLeaderboard("arena", 10, entries -> {
    for (e in entries) trace('${e.position}. ${e.username}: ${e.rating}');
}, err -> ...);   // Array<LeaderboardEntry>
```

### Контекстный API (Elixir, `ExGames.Account`)

```elixir
Account.save_data(user_id, "world1", %{"level" => 3})   # {:ok, Save.t()} | {:error, errors}
Account.get_save(user_id, "world1")                     # {:ok, payload} | {:error, :not_found}
Account.list_saves(user_id)                             # [%{key, updated_at}]
Account.delete_save(user_id, "world1")                  # :ok | {:error, :not_found}
Account.top_ratings("arena", 10)                        # [%{position, user_id, username, rating, ...}]
Account.rating_position(user_id, "arena")               # {:ok, pos} | {:error, :not_found}
```

## Что НЕ хранится в БД

- Листинги матчмейкинга — ETS (аналог Colyseus `LocalDriver`); при
  multi-node — Redis (см. ARCHITECTURE.md).
- Состояние активных комнат — память процесса `Room.Server`; комнаты
  `:temporary`. Снапшоты состояния при dispose/рестарте — отдельная
  будущая возможность (wire-map кладётся в `state_snapshot` как есть).
