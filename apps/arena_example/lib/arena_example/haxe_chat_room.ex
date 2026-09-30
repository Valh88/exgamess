defmodule ArenaExample.HaxeChatRoom do
  @moduledoc """
  Чат, чья серверная логика написана на Haxe и скомпилирована в Lua-чанк
  (`server_scripts/chat/ChatHx.hx` → `priv/lua/chat/ChatHx.lua`, сборка —
  `gamessa run`). Оболочка подключает мост `ExGames.Room.Logics.Lua` с
  опцией `lua_haxe: true` — адаптер ставит шимы рантайма Haxe перед
  загрузкой чанка. Регистрируется в boot как тип комнаты `"haxe_chat"`.

  Обновление логики: правка ChatHx.hx → `gamessa run` → новые комнаты
  получают новый чанк (живые держат старую VM — перезапуск через
  dispose). Версия логики видна клиентам в payload "joined" (`v`).
  """

  use ExGames.Room,
    max_clients: 16,
    patch_rate: 100,
    state_sync: :delta,
    logic: [ExGames.Room.Logics.Lua],
    lua_script: Application.app_dir(:arena_example, "priv/lua/chat/ChatHx.lua"),
    lua_haxe: true

  @impl true
  def room_init(_options, _room), do: {:ok, nil}
end
