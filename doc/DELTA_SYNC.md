# Дельта-синхронизация состояния комнаты

Как комната доставляет клиентам игровое состояние: полные снапшоты и
инкрементальные патчи. Протокол кадров — [PROTOCOL.md](PROTOCOL.md),
архитектура — [ARCHITECTURE.md](ARCHITECTURE.md), матчмейкинг —
[MATCHMAKING.md](MATCHMAKING.md).

---

## 1. Что такое «состояние»

Синхронизируется **только то, что игровой код явно опубликовал** через
эффект `set_state/2` (доступен и комнате, и модулям `Room.Logic`):

```elixir
# ArenaExample.Rules — после move/hit/join:
set_state(room, %{
  "mode"    => state.mode,
  "players" => state.players,   # %{session_id => %{"x" => …, "y" => …}}
  "scores"  => state.scores
})
```

Не синхронизируется никогда:

* срезы состояния `Room.Logic`-модулей (очередь, колода, секреты) — игра
  сама решает, что выставить наружу;
* инфраструктура комнаты (`%__MODULE__{}`: клиенты, мониторы, таймеры).

Формат — wire-map: строковые ключи, msgpack-совместимые значения
(структуры конвертирует `ExGames.Serialization`). Секретное состояние в
`set_state` не кладут: это широковещательный канал; персональное — через
`send_to/4`.

## 2. Режимы

Опция комнаты (по умолчанию `:snapshot`):

```elixir
use ExGames.Room, state_sync: :delta   # или :snapshot
```

| режим | поведение |
|---|---|
| `:snapshot` | на каждом изменённом тике — полный кадр `ROOM_STATE` (14) |
| `:delta` | первый раз — полный `ROOM_STATE`; далее на изменённом тике — `ROOM_STATE_PATCH` (15) только с изменениями |

Каденс — `patch_rate` комнаты. Если изменений нет — кадр не отправляется.

## 3. Формат патча

Кадр `[15][msgpack]`, тело — объект с одним ключом `ops`:

```elixir
%{"ops" => [
    %{"p" => ["players", "sKd8", "x"], "v" => 10},   # установить по пути
    %{"p" => ["players", "ann"],       "d" => true}  # удалить ключ
  ]}
```

* `p` — путь от корня состояния, массив строковых ключей (`[]` — корень);
* `v` — любое wire-значение (число, строка, bool, nil, список, вложенный
  map) — клиент присваивает его по пути;
* `d: true` — удалить ключ;
* отсутствующие промежуточные узлы клиент создаёт;
* **массивы патчатся целиком** по пути (внутрь массивов дифф не
  заходит — без index-shift в текущей версии);
* операций нет → кадр не отправляется вовсе.

Операции — «присваивания»: их можно безопасно применить повторно или к
более свежему срезу состояния (идемпотентность — важна для гонок
подключения).

## 4. Жизненный цикл (механика Colyseus)

Механика повторяет референс (Colyseus: `patchRate`, подавление пустых
патчей, full-state до первого патча, resync при reconnext):

```
первое set_state        → ROOM_STATE (полный снапшот) всем
изменённый тик          → diff(last_sent, current) → ROOM_STATE_PATCH всем
  дифф пуст             → кадр не отправляется
новый клиент / reattach → неотправленный дифф — текущим клиентам;
                          новичку — полный снапшот (все сходятся к одной базе)
reconnect               → полный ROOM_STATE (resync)
```

Порядок гарантирован: снапшоты и патчи пушатся из процесса комнаты.

## 5. Клиент (Haxe SDK, gamessa)

Состояние живёт в `room.state` — анонимное дерево (глубокая конвертация
StringMap-дерева из msgpack через `StatePatch.toAnon`: только у анонимных
объектов прямые поля работают на всех таргетах). Тип задаётся параметром
`Room<S>` через аннотацию; динамические ключи map'ов (sid → значение) —
`Dynamic` + `Reflect.field`:

```haxe
typedef ArenaState = {           // typedef от wire-структуры комнаты
    var mode(default, never):String;
    var tick(default, never):Int;
    var players(default, never):Dynamic;  // sid → {x, y, name}
    var scores(default, never):Dynamic;   // sid → Int
}

var room:Room<ArenaState> = client.connectRoom(reservation);  // S = ArenaState

room.onStateChange.add(s -> trace("score: " + Reflect.field(s.scores, room.sessionId)));
```

`onStateChange` срабатывает после полного кадра и после каждого патча;
генерики Haxe стираются — типизация compile-time, структуру сервер не
валидирует. Применение патчей инкапсулировано (`gamessa.StatePatch.applyAnon`:
навигация по путям, автосоздание узлов, удаление, конвертация значений) —
вручную вызывать не нужно.

## 6. Реализация

| сторона | модуль |
|---|---|
| дифф/apply (Elixir, + тесты) | `ExGames.Room.StateDiff` |
| доставка | `ExGames.Room.Server` (`state_sync`, `last_sent_state`, флаш на attach/reattach) |
| применение (Haxe) | `gamessa.StatePatch` |
| статусно-статические тесты | `state_diff_test.exs`, `room_lifecycle_test.exs` (delta-кейс), `arena_integration_test.exs` (E2E), `StatePatchTest.hx` |

## 7. Ограничения и развитие

* массивы — целиком; индексные операции (insert/move) — будущая версия;
* нет «unreliable»-канала (быстрые несущественные поля);
* нет per-client фильтров состояния (разные клиенты видят разный срез);
* сообщения `broadcast/send_to` доставляются немедленно, а не после
  следующего патча (`afterNextPatch` из Colyseus) — при необходимости
  добавляется поверх текущей схемы.
