# Плановое выключение: drain, healthz/readyz

Как нода ExGames вежливо гасится (graceful shutdown) и как
инфраструктура — балансировщик, Docker, оркестратор — узнаёт, жива ли нода
и принимает ли она игроков. Коды закрытия и кадры протокола —
[PROTOCOL.md](PROTOCOL.md); архитектура — [ARCHITECTURE.md](ARCHITECTURE.md).

---

## 1. Пробы для инфраструктуры

Оба эндпоинта публичные (без auth), JSON:

```
GET /healthz   →  200 {"status": "ok"}
GET /readyz    →  200 {"status": "ok"}
               →  503 {"status": "draining"}   (нода опустошается)
```

* **`/healthz`** — liveness: «процесс отвечает». Всегда 200, пока жив HTTP.
  Нет ответа — нода зависла, оркестратору нужно её перезапустить
  (Docker `HEALTHCHECK`, k8s liveness probe).
* **`/readyz`** — readiness: «принимать ли новых игроков». Балансировщик
  перестаёт направлять трафик на ноду, ответившую 503
  (k8s readiness probe, `max_fails` в nginx upstream).

Разделение важное: зависшая нода перезапускается принудительно,
опустошающаяся — просто исключается из балансировки до завершения.

## 2. Drain: что происходит при остановке

Триггер — остановка приложения. Хук `prep_stop/1` в `ExGamesWeb.Application`
вызывает `ExGames.Runtime.Drain.drain()` **до** гашения supervision tree:

```
1. Флаг draining →
     - матчмейкер закрывается: join_or_create/create/join/join_by_id
       возвращают {:error, :draining} → HTTP 503 (новые игроки не заходят);
     - /readyz отвечает 503 (балансировщик снимает ноду с раздачи).
2. Всем живым комнатам уходит cast :drain_dispose:
     - клиентам кадр ошибки + закрытие WS с кодом 4001 «server shutdown»;
     - комната останавливается.
3. Drain ждёт опустошения реестра комнат — не дольше
   config :ex_games, :drain_timeout_ms (по умолчанию 10_000 мс).
   Остатки добивает остановка supervision tree (terminate/2 комнат
   тоже шлёт 4001).
```

Идемпотентно: повторный `drain/1` ничего не ломает. Ожидание не держит
ни GenServer, ни пробы — флаг ставится сразу, а `drain/1` дожидается
опустошения в вызывающем процессе (потоке остановки приложения).

### Что видит клиент

SDK (`gamessa`) получает `onLeave({code: 4001, ...})` — это **плановое**
закрытие, отличимое от обрыва сети (1006) и от ошибки/кика (4002):
клиент может спокойно переподключиться позже или к другой ноде.

| код | смысл | когда |
|----:|-------|-------|
| 4000 | нормальное закрытие | клиент ушёл, комната закрыта (`dispose`) |
| **4001** | **выключение сервера** | **drain / остановка ноды** |
| 4002 | ошибка протокола / кик | invalid frame, rate-limit, kick |

## 3. Использование

### Вручную (обслуживание, деплой за пределами prep_stop)

```elixir
# в remote shell ноды (bin/ex_games remote или iex --remsh):
ExGames.Runtime.Drain.drain()      # опустошить, ждать до 10с
ExGames.Runtime.Drain.draining?()  # => true
```

### Балансировщик / Docker

```yaml
# docker-compose (фаза 4 плана деплоя добавит HEALTHCHECK в Dockerfile):
healthcheck:
  test: ["CMD", "curl", "-sf", "http://localhost:4000/healthz"]
  interval: 10s
  timeout: 3s
  retries: 3
```

Типовой стоп-сценарий деплоя: LB видит 503 на `/readyz` → новый трафик
идёт на другие ноды → `SIGTERM` → `prep_stop` → drain → нода гаснет.

## 4. Конфигурация

```elixir
# Таймаут ожидания опустошения реестра комнат, мс (ядро):
config :ex_games, :drain_timeout_ms, 10_000

# Гейт prep_stop (веб): false отключает drain при остановке приложения.
# В тестах выключен (config/test.exs) — остановка приложения в тесте
# не является плановым выключением сервера.
config :ex_games_web, :prep_stop_drain, true
```

## 5. Устройство

| узел | роль |
|------|------|
| `ExGames.Runtime.Drain` (apps/ex_games) | GenServer: флаг, sweep реестра комнат, ожидание опустошения; `drain/1`, `draining?/0`, `reset/0` (тестовый хук) |
| `ExGames.Room.Server` | cast `:drain_dispose` → 4001 клиентам + stop |
| `ExGames.Matchmaker` | guard `:draining` в join_or_create/create/join/join_by_id |
| `ExGamesWebWeb.HealthController` | `/healthz`, `/readyz` |
| `ExGamesWebWeb.FallbackController` | `{:error, :draining}` → HTTP 503 |
| `ExGamesWeb.Application.prep_stop/1` | вызывает `Drain.drain()` при остановке |

Тесты: `drain_test.exs` (ядро), `health_api_test.exs` (веб).
