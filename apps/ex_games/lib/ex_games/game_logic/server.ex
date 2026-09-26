defmodule ExGames.GameLogic.Server do
  @moduledoc """
  Процесс-владелец логики: стартует адаптер, обслуживает call/tick,
  хранит последнее известное состояние игры.

  Комната вызывает `ExGames.GameLogic.Server.call/4` и `tick/2`; при краше
  нативного процесса адаптер перезапускается (`:transient` под
  `ExGames.LogicSupervisor`) с последним состоянием.

  Опции:

    * `:adapter` — модуль `ExGames.GameLogic.Adapter` (обязателен);
    * `:id` — идентификатор логики (имя в `ExGames.LogicRegistry`);
    * `:tick_rate` — период тика, мс (0/nil — без автотика);
    * прочие опции передаются в `adapter.start_link/1`.
  """

  use GenServer, restart: :transient

  alias ExGames.GameLogic.Server

  @registry ExGames.LogicRegistry

  @type t :: %__MODULE__{
          adapter: module(),
          handle: term(),
          state: ExGames.GameLogic.state(),
          tick_rate: non_neg_integer(),
          last_tick: integer()
        }

  defstruct [:adapter, :handle, :state, tick_rate: 0, last_tick: 0]

  # -------------------------------------------------------------------------

  @doc "Child spec для DynamicSupervisor."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {:logic, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc "Стартует логику; имя регистрируется в `ExGames.LogicRegistry`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc "Вызов функции логики."
  @spec call(ExGames.Id.id(), String.t(), [term()], timeout()) ::
          {:ok, term(), ExGames.GameLogic.state()} | {:error, term()}
  def call(id, fn_name, args \\ [], timeout \\ 5_000) do
    GenServer.call(via(id), {:call, fn_name, args}, timeout)
  end

  @doc "Читает текущее состояние."
  @spec state(ExGames.Id.id()) :: {:ok, ExGames.GameLogic.state()} | {:error, term()}
  def state(id), do: GenServer.call(via(id), :state)

  @doc "Останавливает логику."
  @spec stop(ExGames.Id.id()) :: :ok
  def stop(id) do
    case lookup(id) do
      {:ok, pid} ->
        GenServer.stop(pid, :normal)
        :ok

      :error ->
        :ok
    end
  end

  @doc "Ищет процесс логики."
  @spec lookup(ExGames.Id.id()) :: {:ok, pid()} | :error
  def lookup(id) do
    case Registry.lookup(@registry, id) do
      [] -> :error
      [{pid, _}] -> {:ok, pid}
    end
  end

  defp via(id), do: {:via, Registry, {@registry, id}}

  # -------------------------------------------------------------------------

  @impl true
  def init(opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    case adapter.start_link(opts) do
      {:ok, handle} ->
        state = %__MODULE__{
          adapter: adapter,
          handle: handle,
          state: handle.state,
          tick_rate: Keyword.get(opts, :tick_rate, 0),
          last_tick: System.monotonic_time(:millisecond)
        }

        if state.tick_rate > 0, do: Process.send_after(self(), :tick, state.tick_rate)

        :telemetry.execute([:ex_games, :logic, :started], %{}, %{adapter: adapter})
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:call, fn_name, args}, _from, %Server{} = state) do
    case state.adapter.call(state.handle, fn_name, args, state.state) do
      {:ok, result, new_state} ->
        {:reply, {:ok, result}, %Server{state | state: new_state}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:state, _from, state) do
    {:reply, {:ok, state.state}, state}
  end

  @impl true
  def handle_info(:tick, %Server{} = state) do
    now = System.monotonic_time(:millisecond)
    dt = now - state.last_tick

    case state.adapter.tick(state.handle, dt, state.state) do
      {:ok, new_state} ->
        if state.tick_rate > 0, do: Process.send_after(self(), :tick, state.tick_rate)
        {:noreply, %Server{state | state: new_state, last_tick: now}}

      {:error, reason} ->
        {:stop, {:logic_tick_failed, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state.adapter.stop(state.handle)
    :ok
  end
end
