defmodule ArenaExample.LuaArenaRoom do
  @moduledoc """
  Демо-арена, вся игровая логика которой написана на Lua
  (`priv/lua/arena.lua`) и исполняется VM внутри BEAM.

  Оболочка подключает мост `ExGames.Room.Logics.Lua` — он транслирует
  события комнаты в вызовы скрипта (`M.call`/`M.tick`) и применяет
  вернувшиеся эффекты (broadcast/kick/…); новый state скрипта публикуется
  через `set_state`, дельты уходят клиентам как обычно.

  Скрипт дополнительно отвечает на request `"schema"` документом
  `M.schema` — по нему Haxe-макрос SDK генерирует типизированный
  `Room<ArenaState>` (см. `doc/LUA_SCRIPTING.md`).
  """

  use ExGames.Room,
    max_clients: 8,
    patch_rate: 50,
    state_sync: :delta,
    logic: [ExGames.Room.Logics.Lua],
    lua_script: Application.app_dir(:arena_example, "priv/lua/arena.lua")

  @impl true
  def room_init(_options, _room), do: {:ok, nil}
end
