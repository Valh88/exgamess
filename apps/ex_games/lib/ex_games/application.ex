defmodule ExGames.Application do
  @moduledoc """
  Дерево супервизии ядра ExGames.

  Стратегия `rest_for_one`: каждый следующий ребёнок стартует только после
  успешного старта предыдущего, а при падении предыдущего все последующие
  перезапускаются. Порядок важен:

    1. `Phoenix.PubSub` — шина событий (лобби, presence, кластер).
    2. `ExGames.RoomRegistry` — реестр room_id → pid.
    3. `ExGames.RoomSupervisor` — DynamicSupervisor игровых комнат.
    4. `ExGames.LogicSupervisor` — DynamicSupervisor процессов нативной логики.

  Комнаты и процессы логики — temporary/transient: упавшая комната не
  восстанавливается (игровое состояние утеряно), матчмейкер подчистит её
  листинг по сигналу DOWN от монитора.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: ExGames.PubSub},
      {Registry, keys: :unique, name: ExGames.RoomRegistry},
      {Registry, keys: :unique, name: ExGames.LogicRegistry},
      {DynamicSupervisor, name: ExGames.RoomSupervisor},
      {DynamicSupervisor, name: ExGames.LogicSupervisor},
      ExGames.Matchmaker,
      ExGames.Presence
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: ExGames.Supervisor)
  end
end
