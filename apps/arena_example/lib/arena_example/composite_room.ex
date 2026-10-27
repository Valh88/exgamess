defmodule ArenaExample.CompositeRoom do
  @moduledoc """
  Комната на композитном бандле: два Haxe-модуля (Score + Ticker,
  `server_scripts/composite/Bundle.hx`) в ОДНОМ Lua-чанке и одной VM —
  `gamessa.script.Composite` собирает их в стандартный контракт `M`
  (см. doc/LUA_SCRIPTING.md, «Композитный бандл»). Для моста это обычный
  «один скрипт на комнату» (`lua_haxe: true` — шимы рантайма Haxe).
  Регистрируется в boot как тип комнаты `"composite"`.

  Обновление логики: правка Bundle.hx → `mix ex_games.scripts` → новые
  комнаты на новом чанке (живые держат старую VM — перезапуск через
  dispose).
  """

  use ExGames.Room,
    max_clients: 16,
    patch_rate: 100,
    state_sync: :delta,
    logic: [ExGames.Room.Logics.Lua],
    lua_script: Application.app_dir(:arena_example, "priv/lua/composite/Bundle.lua"),
    lua_haxe: true

  @impl true
  def room_init(_options, _room), do: {:ok, nil}
end
