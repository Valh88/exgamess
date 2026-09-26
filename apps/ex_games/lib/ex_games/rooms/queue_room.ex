defmodule ExGames.Rooms.QueueRoom do
  @moduledoc """
  Очередь подбора (аналог QueueRoom в Colyseus): игроки ждут, раз в тик
  сортируются по рангу, полные группы расформируются в игровую комнату.

  Комната — тонкая оболочка: вся логика подбора живёт во встраиваемом
  модуле `ExGames.Matchmaking.PairsByRank` (`ExGames.Room.Logic`) —
  как правила арены в `ArenaExample.Rules`. Своя стратегия подбора —

      use ExGames.Room, logic: [MyMatchmaking]

  (`logic_join` ставит игроков в очередь, `logic_tick` собирает матчи).

  Опции комнаты (читает стратегия, `logic_init`):

    * `"match_room_name"` — тип игровой комнаты (обязателен);
    * `"group_size"` — размер группы (по умолчанию `2`);
    * `"max_rank_gap"` — максимальный разброс ранков внутри группы
      (по умолчанию `200`); группы из игроков с большим разбросом не
      собираются, пока ожидание < `"priority_after_ms"`;
    * `"priority_after_ms"` — после этого ожидания игрок получает приоритет:
      рассматривается первым, и для его группы гэп по рангам не применяется
      (по умолчанию `10_000`).

  Клиент кладёт ранг в опциях join: `%{"options" => %{"rank" => 1500}}`
  (стратегия переносит его в auth через `logic_auth`; серверный ранг
  в auth — например, из БД — имеет приоритет).

  Как только группа собрана: матчмейкер создаёт игровую комнату, всем
  участникам бронируются места, каждый получает сообщение
  `{"seat", reservation}` — и подключается по нему к игровой комнате.
  """

  use ExGames.Room,
    max_clients: :infinity,
    patch_rate: 1000,
    rate_limit: 120,
    logic: [ExGames.Matchmaking.PairsByRank]

  @impl true
  def room_init(_options, _room), do: {:ok, nil}
end
