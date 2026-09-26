defmodule ExGames.Test.ScoreLogic do
  @moduledoc false
  # Встраиваемая логика для тестов контракта: счёт по сессиям.

  use ExGames.Room.Logic

  @impl true
  def logic_init(options, _room) do
    {:ok, %{scores: %{}, ticks: 0, infos: [], name: Map.get(options, "name", "score")}}
  end

  @impl true
  def logic_join(_room, client, auth, state) do
    start =
      case auth do
        %{"start" => s} when is_integer(s) -> s
        _ -> 0
      end

    {:ok, put_in(state, [:scores, client.session_id], start)}
  end

  @impl true
  def logic_leave(_room, client, _reason, state) do
    {:ok, Map.put(state, :scores, Map.delete(state.scores, client.session_id))}
  end

  @impl true
  def logic_tick(_elapsed, state), do: {:ok, Map.update!(state, :ticks, &(&1 + 1))}

  @impl true
  def logic_info(msg, state), do: {:ok, Map.update(state, :infos, [msg], &[msg | &1])}

  message "add", %{"n" => n}, room, client, state do
    new = state.scores[client.session_id] + n
    broadcast(room, "score", %{"session_id" => client.session_id, "value" => new})
    {:ok, put_in(state, [:scores, client.session_id], new)}
  end

  request "scores", _payload, _room, _client, state do
    {:reply, state.scores, state}
  end
end

defmodule ExGames.Test.GateLogic do
  @moduledoc false
  # Логика-шлюз: отклоняет бронь по auth-признаку.

  use ExGames.Room.Logic

  @impl true
  def logic_init(_options, _room), do: {:ok, %{}}

  @impl true
  def logic_auth(%{"deny" => true}, _options, _room), do: {:error, :denied}
  def logic_auth(_auth, _options, _room), do: :ok
end

defmodule ExGames.Test.LogicShell do
  @moduledoc false
  # Комната-оболочка с двумя встроенными логиками + собственная клауза.

  use ExGames.Room,
    max_clients: 4,
    patch_rate: 20,
    logic: [ExGames.Test.ScoreLogic, ExGames.Test.GateLogic]

  @impl true
  def room_init(_options, _room), do: {:ok, %{}}

  message "ping", _payload, room, client, state do
    send_to(room, client.session_id, "pong", %{})
    {:ok, state}
  end
end
