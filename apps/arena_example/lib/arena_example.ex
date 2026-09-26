defmodule ArenaExample do
  @moduledoc """
  Демо-игра на фреймворке ExGames: полный цикл от регистрации до матча.

  Комнаты (регистрируются в `ArenaExample.Boot`):

    * `"chat"` — глобальный чат (`ExGames.Rooms.Chat`, канал `global`);
    * `"lobby"` — листинг комнат (`ExGames.Rooms.Lobby`);
    * `"queue"` — очередь 2×2 по рангу (`ArenaExample.QueueRoom`);
    * `"arena"` — арена 8 игроков (`ArenaExample.ArenaRoom`).

  Запуск: `mix setup && mix phx.server` (из корня umbrella).
  """
end
