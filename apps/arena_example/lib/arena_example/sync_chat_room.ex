defmodule ArenaExample.SyncChatRoom do
  @moduledoc """
  Чат на `gamessa.script.Sync` — типизированные @:rpc-методы поверх
  ServerLogic (`server_scripts/chatsync/ChatSync.hx` →
  `priv/lua/chatsync/ChatSync.lua`, сборка — `mix ex_games.scripts`).
  От обычного Haxe-чата отличается request-методами: `seq` и `history`
  отвечают клиенту значением (кадр RoomResponse), `say` — как раньше,
  broadcast-сообщение. Регистрируется в boot как тип комнаты
  "sync_chat"; та же логика типизирует клиентский стаб (см. SDK
  example).

  Обновление логики: правка ChatSync.hx → `mix ex_games.scripts` →
  новые комнаты на новом чанке (живые держат старую VM — перезапуск
  через dispose). Версия логики видна клиентам в payload "joined" (`v`).
  """

  use ExGames.Room,
    max_clients: 16,
    patch_rate: 100,
    state_sync: :delta,
    logic: [ExGames.Room.Logics.Lua],
    lua_script: Application.app_dir(:arena_example, "priv/lua/chatsync/ChatSync.lua"),
    lua_haxe: true

  @impl true
  def room_init(_options, _room), do: {:ok, nil}
end
