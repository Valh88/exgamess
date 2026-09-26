defmodule ArenaExample.ArenaRoom do
  @moduledoc """
  Демо-арена: оболочка комнаты до 8 игроков с тиком 50 мс.

  Вся игровая логика (движение, счёт, публикация состояния) живёт во
  встраиваемом модуле `ArenaExample.Rules` (`ExGames.Room.Logic`) —
  оболочка только объявляет его и опции. Так комната остаётся тонкой:
  правила можно тестировать отдельно, переиспользовать в других комнатах
  или позже вынести в нативный процесс через `ExGames.GameLogic`.
  """

  use ExGames.Room,
    max_clients: 8,
    patch_rate: 50,
    logic: [ArenaExample.Rules]

  @impl true
  def room_init(_options, _room), do: {:ok, nil}
end
