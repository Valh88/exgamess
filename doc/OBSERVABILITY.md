# Наблюдаемость: телеметрия, метрики, /metrics

Доменные метрики ExGames без внешних зависимостей: `:telemetry`-события
из кода ядра, ETS-агрегатор `ExGames.Telemetry` (счётчики + gauge'и
«последнее значение»), текстовый Prometheus-эндпоинт `GET /metrics` и
панель «Метрики ноды» в админ-дашборде.

## События домена

| событие | измерения | смысл |
|---------|-----------|-------|
| `[:ex_games, :room, :created]` / `:disposed` | — | жизненный цикл комнаты |
| `[:ex_games, :room, :join]` / `:rejoin` / `:leave` | `count` (клиентов в комнате) | подключения; rejoin — reconnect-флоу |
| `[:ex_games, :room, :kick]` | — | кик через `Room.kick/2` |
| `[:ex_games, :room, :message]` | `count`, `duration_ms` | обработка кадра `ROOM_DATA` (с диспетчеризацией в логики) |
| `[:ex_games, :room, :ping]` | `rtt` | клиент-отчётный RTT (см. ping-компенсацию) |
| `[:ex_games, :room, :set_state]` | — | документ состояния применён |
| `[:ex_games, :room, :set_state_rejected]` | — | документ отклонён гейтом схемы (см. ниже) |
| `[:ex_games, :room, :logic_lua_call]` | `count`, `duration_ms` | вызов Lua/Haxe-скрипта (message/join/leave/tick/request) |
| `[:ex_games, :room, :logic_lua_error]` | — | ошибка скрипта (включая нарушение схемы состояния) |
| `[:ex_games, :room, :logic_lua_unknown_effect]` | — | эффект вне whitelist моста |
| `[:ex_games, :logic, :started]` | — | старт нативной логики (GameLogic) |
| `[:ex_games, :queue, :matched]` | `count` | матчмейкер собрал группу |
| `[:ex_games, :matchmaker, :room_gone]` | — | подчистка листинга упавшей комнаты |

Новые события добавляются в список подписки агрегатора
(`@event_names` в `ExGames.Telemetry`) — `:telemetry` диспетчеризует
только по **полным** именам, префиксной привязки нет.

## Агрегатор ExGames.Telemetry

Обработчик слушает перечисленные события и пишет в публичную ETS:

* **счётчик** на каждый путь события (`room.join`) — сколько раз;
* **gauge** на каждое числовое измерение (`room.ping.rtt`,
  `room.message.duration_ms`) — последнее значение.

Каждые 10 с сэмплер пишет gauge'и ноды:

| gauge | источник |
|-------|----------|
| `node.rooms_active` | живые комнаты (Registry) |
| `node.clients_in_rooms` | сумма `clients` по листингам матчмейкера |
| `node.online` | `ExGames.Presence` |
| `node.memory_bytes` | память BEAM |
| `node.process_count` | число процессов |

Чтение: `ExGames.Telemetry.snapshot/0` (map, для админки) и
`ExGames.Telemetry.prometheus/0` (текст). Агрегатор — элемент дерева
`ExGames.Application`; события он собирает с момента старта ноды.

## GET /metrics

Текстовый формат Prometheus 0.0.4 (`text/plain; version=0.0.4`),
счётчики получают суффикс `_total` (`ex_games_room_created_total`),
gauge'и — без (`ex_games_node_memory_bytes`). Эндпоинт без auth: значения
— агрегаты ноды, персональных данных и идентификаторов комнат нет.
Для скрейпера (Prometheus, Datadog agent, bash+curl).

## Админ-панель

* **Обзор** — панель «Метрики ноды»: доменные счётчики и gauge'и
  снапшотом (с последнего старта ноды).
* **Комната → Состояние (set_state)** — снапшот, схема состояния логики
  (из `M.schema`, если есть) и форма «Установить состояние»: JSON-документ
  проверяется `ExGames.Room.StateSchema.validate_root/2` **до отправки**;
  отклонённый — ошибка с путём, применённый — cast в комнату (гейт сервера
  перепроверит).

## Валидация set_state по схеме состояния

Все пути записи состояния проходят проверку по `M.schema.state` скрипта
(`ExGames.Room.StateSchema`):

* **Lua/Haxe-мост** превалидирует состояние скрипта перед публикацией:
  нарушивший схему документ не уходит клиентам (остаётся прежний стейт),
  скрипт продолжает со своего, каждый переход — warning + телеметрия
  `logic_lua_error` (`state_schema`). Превалидация именно в мосту — иначе
  гейт сервера откатил бы стейт под ногами у скрипта (у LogicServer
  документ уже новый).
* **Гейт в `Room.Server`** (второй рубеж) — для прямых cast'ов
  (`Room.set_state/2`, `Room.set_state_branch/3`): при нарушении схемы
  документ отбрасывается целиком, стейт комнаты не меняется,
  warning + `[:ex_games, :room, :set_state_rejected]`. Схемы берутся из
  логик при старте комнаты (`__state_schema__/1` — у моста, из
  `M.schema.state`), карта доступна через
  `ExGames.Room.Server.state_schemas/1` (админка).
  Две логики с одним ключом схемы (например, два корня без `state_key`)
  конфликтуют — ключ отключается, остаётся превалидация в мостах.
* **Комнаты без схемы состояния** (Elixir-логики, скрипты без `M.schema.state`)
  принимают любой документ — валидация не мешает.

Формат схемы: лист — `"number" | "string" | "boolean" | "any"`,
контейнер — `%{"map" => schema}` / `%{"list" => schema}`, структура —
map «поле → схема». В документе `nil` проходит против любого дескриптора;
в структуре неизвестное поле — ошибка, отсутствующее — ок.

## Тесты

* core: `state_schema_test.exs` (валидатор), `telemetry_test.exs`
  (агрегатор/сэмплер/прометей), `room_logics_lua_test.exs` (мост не
  публикует ломающий стейт; гейт отбрасывает чужой документ — корень и
  ветки `state_key`);
* web: `metrics_api_test.exs` (`/metrics`), `admin_live_test.exs`
  (форма set_state: успех и некорректный JSON; панель метрик дашборда).
