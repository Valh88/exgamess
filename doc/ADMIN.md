# Админ-панель (LiveView)

Тёмная консоль по `/admin` в `ex_games_web`: управление пользователями,
живой обзор комнат, presence, дренаж. Отдельная входная точка —

    mix phx.server
    # → http://127.0.0.1:4000/admin (логин: admin / admin123123 из сидов)

## Auth: одна база аккаунтов, два транспорта

Второго комплекта паролей нет. Логин админки — существующий
`ExGames.Account.login/2`: та же таблица `users`, те же роли
(player / moderator / admin), те же баны. Различие только в **транспорте**
факта «это админ»:

| Клиент | Транспорт | Где проверяется |
|---|---|---|
| Игровые клиенты (SDK) | `Authorization: Bearer` | `Plugs.Auth` → `/api/admin/*` |
| Браузер (админка) | cookie-сессия (`admin_uid`) | `on_mount`-гвардия `Admin.Auth` |

LiveView 1.x не умеет писать сессию, поэтому форма логина через
`phx-trigger-action` делает обычный POST на
`AdminSessionController.create/2` — он проверяет логин/роль/бан, кладёт
`admin_uid` в сессию и перенаправляет в панель. Выход —
`DELETE /admin/logout` (очистка сессии).

Гвардия `ExGamesWebWeb.Admin.Auth.on_mount(:ensure_admin, …)` выполняется
на **каждый** mount: бан или снятие роли «на лету» закрывают доступ при
следующей навигации. Все страницы живут в `live_session :admin` с этой
гвардией; страница логина — в отдельном `live_session :admin_login`.

`mix phx.gen.auth` сознательно не используется — он генерирует вторую
таблицу users со своими паролями.

## Страницы

- **`/admin` — Обзор.** Стат-карты (пользователи, онлайн, живые комнаты,
  клиенты в комнатах), бейдж draining, счётчики живых комнат по типам
  (`Matchmaker.definitions/0`). Опрос 2 с — все чтения дешёвые
  (ETS/Registry/Tracker + один агрегат БД). Кнопки **Drain** / **Reset**:
  `Drain.drain/1` блокирующий (до `:drain_timeout_ms`), поэтому
  выполняется в `Task`.
- **`/admin/users` — Пользователи.** Поиск по username, фильтры (роль,
  бан), пагинация 25/стр. Действия: бан с причиной, разбан, выдача роли
  (`+ роль…` в строке), снятие роли (кнопка `− роль`). Коллекция —
  LiveView stream.
- **`/admin/users/:id` — Профиль.** Роли, причина бана, облачные
  сохранения (`list_saves/1`), рейтинги по играм (`user_ratings/1`).
- **`/admin/rooms` — Комнаты.** Живые комнаты: листинг матчмейкера +
  `Room.Server.listing/1` (модуль, возраст). Обновления вживую:
  подписка на лобби-топик `ExGames.Matchmaker.lobby_topic()` (сообщения
  `{:ex_games, :lobby, {:update | :remove, …}}`) + опрос 5 с. Действия:
  lock/unlock, dispose (двухшаговое подтверждение). Комнаты без типа
  (созданные по room_id) в листинге не публикуются — их видно только
  через join_by_id.
- **`/admin/rooms/:id` — Детали комнаты.** Клиенты
  (`Room.Server.clients_detailed/1`: session_id, user_id из auth,
  joined_at, RTT) с киком per-client; снапшот синхронизируемого
  состояния (`Room.Server.state_snapshot/1`, read-only, рендер
  обрезается на ~20 КБ).
- **`/admin/online` — Онлайн.** `Presence.list_online/0` + живые
  join/leave (`Presence.subscribe()` → бродкасты из `handle_diff`).
  Заполняется автоматически: `Room.Server` трекает пользователя при
  attach (`Presence.track_room_user/3`, user_id + username из auth-данных
  брони; анонимные комнаты без user_id не трекаются) и снимает при уходе.
  Юзер в нескольких комнатах остаётся одной записью (держатель — комната,
  `list_online_entries/0` даёт разрез юзер×комната).

## Серверные API, добавленные под панель

- `ExGames.Account.list_users/1` — `[search:, role:, banned:, page:, page_size:]`
  → `%{entries, total, page, page_size}` (REST `GET /api/admin/users`
  переведён на него);
- `ExGames.Account.fetch_user_by_id/1` — публичный (был приватный);
- `ExGames.Account.user_ratings/1` — рейтинги юзера по играм;
- `ExGames.Room.Server.clients_detailed/1` — полный `%Client{}` вместо
  списка session_id;
- `ExGames.Room.Server.state_snapshot/1` — read-only снимок `game_state`;
- `created_at` в `%Room.Server.State{}` и в `listing/1`.

## Расширение

Страница = модуль `live/admin/<name>_live.ex` + роут в `live_session :admin`
+ строка в **`ExGamesWebWeb.Admin.Nav`** (единственное место с навигацией).
Компоненты тёмной консоли — `ExGamesWebWeb.AdminComponents` (`stat_card`,
`badge`, `panel`, `admin_table` — со streams, `admin_button`): чистый
Tailwind без daisyUI (правило проекта), строки интерфейса на русском без
gettext (одна локаль). Будущие разделы (метрики `[:ex_games, *]` через
`:telemetry.attach`, очередь матчмейкинга, аудит) ложатся без изменений
лейаута.

## Тесты

`test/ex_games_web_web/admin_live_test.exs` (14): гвардия (аноним/не-админ
→ редирект), вход через trigger-action (админ ок, игрок отказ), выход,
поиск/фильтр, бан с причиной + разбан, роли, детали юзера, комнаты
(lock/dispose), детали комнаты, presence. Грабля, зафиксированная
тестами: **parent-assign внутри stream-строк не обновляет их содержимое**
— при изменении такого assign нужно пере-стримить коллекцию
(`stream(…, reset: true)`), см. ask_dispose.
