# Lua-скриптинг серверной логики

Комнаты, чья игровая логика написана на Lua и исполняется VM
[`lua`](https://lua.hexdocs.pm/Lua.html) (tv-labs, Lua 5.3 на чистом
Elixir, без NIF — Windows-friendly) внутри BEAM. Реализованы все пять
этапов плана `.zcode/plans/plan-lua-scripting-server-logic.md`.

## Слои контрактов

```
Room.Server (процесс комнаты)
 └─ Room.Logic-модули ............ контракт встраивания (события + DSL-эффекты)
     ├─ обычный Elixir-модуль (ArenaExample.Rules)
     └─ мост ExGames.Room.Logics.Lua — пересылает события скрипту
           └─ GameLogic.Server (id = room_id или {room_id, module})
               └─ GameLogic.Adapters.Lua (4 колбэка Adapter-контракта)
                   └─ Lua-скрипт: таблица M (init/call/tick)
```

Комната не знает, где исполняется логика; Lua-скрипт не видит ни комнаты,
ни Elixir — только вызовы и документы.

## Контракт скрипта (таблица `M`)

```lua
M = {}

function M.init(args)              -- старт LogicServer'а / рестарт адаптера
  return { players = {}, scores = {} }
end

function M.call(fn, args, state)   -- join / leave / message
  if fn == "join" then
    local sid = args[1]            -- args = [sid, auth]
    state.players[sid] = { x = 0, y = 0, hp = 100 }
    return { { "broadcast", "player_joined", { sid = sid } } }, state
  elseif fn == "message" then
    local msg, sid, payload = args[1], args[2], args[3]
    -- ...
  end
  return state                     -- одиночное значение = новый state
end

function M.tick(dt, state)         -- тик комнаты (мост драйвит VM вручную)
  return state
end
```

Правила возврата:

* одно значение — новый state;
* пара — `{result, state}`; в глазах моста `result` — **список эффектов**.

## Эффекты (whitelist моста)

Скрипт не может вызывать Elixir: он возвращает список эффектов, мост
применяет их через DSL комнаты. Неизвестный эффект — телеметрия + игнор
(комнату не роняем). Нужен новый побочный эффект — добавьте клейзу в
`ExGames.Room.Logics.Lua.apply_effect/2` (явно и с телеметрией), а не
доступ скрипта к рантайму.

```lua
{ "broadcast", type, payload }
{ "send_to", session_id, type, payload }
{ "kick", session_id }
{ "lock" }        { "unlock" }
{ "set_metadata", map }
```

### Как добавить новый эффект

1. Конструктор в `gamessa.script.Effect` (SDK). Понижение `__lower`
   генерируется макросом интроспекцией enum'а по конвенции
   **тег = snake_case(имя конструктора), аргументы — по порядку
   объявления** — Haxe-сторона готова сразу (`Signal(to, msg)` →
   `["signal", to, msg]`, нуль-аргументный `Fire` → `["fire"]`).
2. Ветка в `ExGames.Room.Logics.Lua.apply_effect/2` — whitelist
   сервера расширяется осознанно, автогенерации нет.
3. Проверки понижения — в `ServerLogicTest.testLowerEffects`.

## Документы

Состояние и аргументы — msgpack-совместимые документы (map со строковыми
ключами, list, binary, число, bool, nil). Lua-таблицы нормализуются
(`Adapters.Lua.validate_doc/1`): таблица с целыми ключами → список (дыры
схлопываются, порядок по возрастанию ключей), иначе → map со строковыми
ключами; пустая таблица → `%{}`; функции/tref (циклы)/userdata → ошибка с
путём (`$.players.2: function`).

Состояние передаётся скрипту **каждым вызовом** (модель нативных
адаптеров): владелец — `GameLogic.Server`, краш/рестарт адаптера не теряет
игру (рестарт = свежий `M.init`). Ошибка скрипта → `{:error, {:lua, msg}}`
с `source:line`; состояние остаётся прежним. Бюджет инструкций
(`:max_instructions`, default 1_000_000 на вызов) и `:max_call_depth`
(default 200) — runaway-скрипт даёт ошибку, а не зависание. Песочница VM
блокирует io/file/os/package/load/require из коробки; заметено на тестах:
`os.execute` недоступен, кириллица — строкой, integer/float различаются.

## Мост `ExGames.Room.Logics.Lua`

Прямой режим (один скрипт на комнату — модель по умолчанию):

```elixir
use ExGames.Room,
  max_clients: 8,
  patch_rate: 50,
  state_sync: :delta,
  logic: [ExGames.Room.Logics.Lua],
  lua_script: Application.app_dir(:my_app, "priv/lua/arena.lua"),
  lua_args: []            # опционально
  # max_instructions / max_call_depth — опционально
```

Скрипт ищется в опциях комнаты (compile-time `lua_script` или create-опция
`"lua_script"` — create-приоритет). Мост — wildcard-модуль `Room.Logic`
(клейза `message :_`): join/leave/tick/сообщения → `M.call`/`M.tick`;
новый state публикуется `set_state/2` **только при изменении**; тики
драйвятся мостом (`GameLogic.Server.tick/1`, авто-тик Server'а выключен).
Ошибка скрипта — телеметрия + игнор. Мост отвечает на request `"schema"`
документом `M.schema`.

### Несколько Lua-модулей

```elixir
defmodule MyGame.PhysicsLua do
  use ExGames.Room.Logics.Lua, script: "priv/lua/physics.lua"
end

use ExGames.Room, logic: [MyGame.PhysicsLua, MyGame.EconomyLua]
```

Диспетчеризация — по типам из `M.schema.messages` (headless-прогон скрипта
при первом обращении, кэш `:persistent_term`); скрипт без схемы (или
`wildcard: true`) ловит все типы. Каждому модулю — своя VM, свой срез
состояния и свой `GameLogic.Server` с id `{room_id, module}`. Оговорка:
срезы, пишущие в общие ветки set_state-дерева, затирают друг друга —
мульти-модули для разнесённых срезов (`physics/`, `economy/`).

## Схема и типизированный клиент (Haxe)

Скрипт объявляет `M.schema`:

```lua
M.schema = {
  messages = { "move", "hit" },
  state = {
    players = { map = { x = "number", y = "number", hp = "number" } },
    scores  = { map = "number" },
  },
}
```

1. `mix ex_games.lua_schema priv/lua/arena.lua` → JSON-артефакт
   `priv/lua/arena.schema.json` (коммитится; в рантайме тот же документ
   отвечает request `"schema"`).
2. Haxe-макрос `gamessa.script.Schema` читает артефакт на компиляции и
   генерирует в модуль аннотированного класса `typedef <Prefix>State` +
   `<Prefix>Msg` (static inline имена сообщений):

   ```haxe
   @:build(gamessa.script.Schema.build("arena.schema.json", "LuaArena"))
   class LuaArenaScript {}

   var room:Room<LuaArenaState> = ...;
   room.send(LuaArenaMsg.Move, {x: 1, y: 0});
   room.state.players[sid].hp;   // players: DynamicAccess<{x:Float, ...}>
   ```

Схема → Haxe: `"string"/"number"/"boolean"` → `String/Float/Bool`;
`{"list": S}` → `Array<T>`; `{"map": S}` → `haxe.DynamicAccess<T>` (стейт
на клиенте — анонимные объекты, см. `StatePatch.toAnon`); таблица полей →
анонимная структура. Клиентский контракт — данные из схемы + клиентский
API SDK (`onStateChange`/`onMessage`/`send`), не зеркальные колбэки
`Room.Logic`.

## Общая логика сервера и клиента (спайк Haxe→Lua — **go**, реализовано)

`sdk/lua-spike/`: один Haxe-исходник компилируется `-lua` и исполняется
под песочницей VM; все SPIKE-проверки (классы, анонимные структуры,
Array/Map, float-арифметика, битовые операции, строки) проходят.

## Haxe-скрипты на сервере (шимы — реализовано)

Чанк `haxe -lua` работает как обычный `lua_script:` — при опции
`haxe: true` адаптер перед загрузкой ставит шимы рантайма Haxe
(`ExGames.GameLogic.Adapters.Lua.Shims`):

```elixir
# прямой режим
use ExGames.Room, logic: [ExGames.Room.Logics.Lua],
  lua_script: "priv/lua/game_haxe.lua", lua_haxe: true

# тонкий модуль мульти-Lua
use ExGames.Room.Logics.Lua, script: "priv/lua/physics_haxe.lua", haxe: true
```

Шимы (`Lua.Shims`): utf8 → Elixir `String.*` (полный юникод);
`bit32`/`bit` → нативные 5.3-операторы; `package`/`require` — управляемые
заглушки (посторонние модули по-прежнему `require blocked`); плюс
`__hx_toplain(v)` — нормализатор Haxe-структур в plain-документы.
Без `haxe: true` Haxe-чанк не загрузится (прелюдия зовёт `require`);
интроспекция `M.schema` (`extract_schema`, mix-задача) шимы ставит всегда.

## ServerLogic — типизированные Haxe-скрипты (рекомендуемый путь)

SDK (gamessa) остаётся библиотекой без бизнес-логики — `gamessa.script`
содержит только generic-инфраструктуру: базовый класс, эффекты, аргументы,
билдер. Бизнес-логика — в примерах/приложениях.

```haxe
import gamessa.script.Effect;
import gamessa.script.ScriptArgs;

// тип состояния = схема (Int/Float→number, String→string, Bool→boolean,
// DynamicAccess<X>→map, Array<X>→list, структура→таблица, Dynamic→"any")
typedef ChatMsg = {n:Int, sid:String, name:String, text:String};
typedef ChatState = {
  seq:Int,
  version:Int,
  users:haxe.DynamicAccess<String>,
  history:haxe.DynamicAccess<ChatMsg>,
};

class ChatHx extends gamessa.script.ServerLogic<ChatState> {
  public static function messages():Array<String>   // M.schema.messages
    return ["say", "history"];

  override function init(_args:Dynamic):ChatState
    return {seq: 0, version: 1, users: {}, history: {}};

  // state типизирован; эффекты — типизированный enum
  override function call(fn:String, args:ScriptArgs, state:ChatState):Array<Effect> {
    if (fn == "message" && args.get(1) == "say") {
      state.seq = state.seq + 1;
      return [Broadcast("say", {n: state.seq, text: args.get(3).text})];
    }
    return null;   // null = без эффектов
  }

  override function tick(dt:Float, state:ChatState):Void {}
}
```

Билдер (`@:autoBuild`) генерирует в наследника: Lua-биндинг M с
`__hx_toplain` на границах (только под `-lua`, `@:keep` включён),
`M.schema.state` из typedef-а, `__lower` — понижение `Array<Effect>`
в сырые массивы контракта, `ScriptWire.fromWire` — развёртку wire-вызова
в `ScriptFn`. На hl/js класс — обычный Haxe: **клиентское
переиспользование** — те же init/call/tick вызываются напрямую над копией
стейта (предикт), `Room<ChatState>` типизируется тем же typedef-ом —
JSON-схема для Haxe-скриптов не нужна. Вызовы уже типизированы:
`ScriptFn` (Join(sid, auth) / Leave(sid, reason) / Message(type, sid,
payload)); позиционная магия (`ScriptArgs.get(i)`, 1-based) осталась
только в сыром пути без SDK.

## Пример: Haxe-чат (arena_example, тип комнаты `haxe_chat`)

Рабочий образец «создание скрипта → комната → обновление логики» на
`ServerLogic`:

* `apps/arena_example/server_scripts/chat/ChatHx.hx` — чат на Haxe
  (typedef ChatState, Effect, ScriptArgs; join с именем из auth + версия
  логики `v`, say, history через `send_to`, leave); сборка —
  `gamessa run` (или `mix ex_games.scripts`) → `priv/lua/ChatHx.lua`;
* `HaxeChatRoom` — оболочка (`lua_script` + `lua_haxe: true`), boot
  регистрирует `"haxe_chat"`;
* `priv/lua/ChatHx.schema.json` — сгенерирован mix-задачей (включает
  типизированный `state` из typedef'а);
* интеграционный тест `haxe_chat_integration_test.exs` — два клиента по
  WS: say виден обоим (включая кириллицу), history только отправителю,
  request `"schema"` возвращает типизированную схему, `left` при кадре
  `leave_room`.

Workflow обновления логики: правка `ChatHx.hx` → `gamessa run` →
**новые** комнаты получают новый чанк; живые комнаты продолжают на
старой VM (перезапуск — dispose через админку `/admin/rooms` или
`Rooms.stop/1`). Версия логики видна клиентам в payload `"joined"` (`v`).
Схема (`ChatHx.schema.json`) освежается той же `mix ex_games.scripts`.

## Ветки состояния мульти-Lua (state_key)

Мульти-модули публикуют свои документы в общее `game_state`; без
изоляции публикация одного модуля заменяла бы корень целиком. Опция
моста `state_key:` публикует документ модуля в СВОЮ корневую ветку
(`Room.set_state_branch/3` → `game_state[key] = doc`), не трогая
остальные:

```elixir
defmodule MyGame.PhysicsLua do
  use ExGames.Room.Logics.Lua, script: "priv/lua/physics.lua", state_key: "physics"
end
```

Клиент видит `game_state = %{physics => ..., economy => ...}`; тип
`TState` скрипта описывает содержимое СВОЕЙ ветки. Прямой режим (без
`state_key`) по-прежнему публикует документ как весь корень.

## Сборка скриптов: server_scripts и `gamessa run`

Конвенция проекта, использующего gamessa — **скрипты живут в проекте
сервера** (это его бизнес-логика; SDK — только библиотека каркаса):

    <root>/server_scripts/**/Xxx.hx        — РЕКУРСИВНО: каждый .hx (любая
        глубина), наследующий ServerLogic, — отдельный скрипт
    <root>/priv/lua/<путь>/Xxx.lua         — чанк (ЗЕРКАЛО дерева server_scripts;
        путь — для lua_script: моста)
    <root>/priv/lua/<путь>/Xxx.lua.schema.json — схема (сервер-раннер)

Никаких script.json: раннер сам находит ServerLogic-наследников. Общие
исходники (.hx без ServerLogic в том же каталоге) подхватываются через
-cp и отдельно не собираются.

Два входа в один и тот же результат:

* **gamessa run** (SDK-сторона; haxe компилирует — ему и рожать):

      haxelib run gamessa run [roots...]   # установленный haxelib
      hl sdk/gamessa/bin/run.hl run apps/arena_example   # напрямую

  Раннер — bin/run.hl (коммитится; пересборка: `haxe tools/build_run.hxml`
  из каталога SDK).

* **mix ex_games.scripts** (серверная обёртка из корня зонда):

      mix ex_games.scripts                  # чанки + схемы
      mix ex_games.scripts --schemas-only   # только схемы

  Автоматически регенерирует `*.schema.json` (headless-прогон чанка в VM).

Подключение SDK — через **haxelib** (один раз):

    haxelib dev gamessa D:/projects/.../sdk/gamessa   # dev-ссылка на исходники

Тогда оба раннера компилируют с `-lib gamessa` — и haxelib **сам
подтягивает зависимости либы** в сборку скриптов. Fallback без haxelib:
findUp `<root>/sdk/gamessa/source` или env GAMESSA_SDK (обычный `-cp`).

Рекомендация по размещению: чанки и схемы `priv/lua/` **коммитятся** —
серверу и клиенту haxe в рантайме не нужен; перезапуск живых комнат
после обновления — dispose (админка/`Rooms.stop/1`). Путь чанка в
`lua_script:` — любой (не обязан быть в priv/lua): если скрипты проекта
компилируются в другое место, просто укажите его.

## Ограничения и запасной вариант

* VM `lua` — интерпретатор на BEAM: сценарий «правила, не физика»;
  сопрограмм и полноценного GC/debug нет.
* `M.schema` объявляется таблицей (или функцией) — вырожденные формы
  (функции внутри) отсекаются `validate_doc`.
* Запасной VM — `luerl` (Erlang): тот же контракт адаптера, замена только
  адаптера.

## Пример и тесты

* `apps/arena_example/priv/lua/arena.lua` + `LuaArenaRoom` — мини-арена
  (join/move/hit/tick-респавн), зарегистрирована как `"lua_arena"`.
* `apps/ex_games/test/ex_games/lua_adapter_test.exs` — адаптер (19 тестов).
* `apps/ex_games/test/ex_games/room_logics_lua_test.exs` — wildcard-DSL,
  мост, эффекты, устойчивость к ошибкам, мульти-Lua.
* `apps/arena_example/test/lua_arena_integration_test.exs` — полный
  HTTP/WS-сценарий (matchmake → join → move/hit → патчи → schema).
* `apps/ex_games/test/ex_games/haxe_lua_spike_test.exs` — вердикт спайка.
