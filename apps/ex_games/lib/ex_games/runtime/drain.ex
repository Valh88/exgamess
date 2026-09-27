defmodule ExGames.Runtime.Drain do
  @moduledoc """
  Плановое опустошение ноды (graceful shutdown, как в Colyseus).

  Вызывается при остановке приложения (хук `prep_stop/1` веб-приложения,
  до гашения supervision tree):

    1. Флаг `draining` — матчмейкер перестаёт выдавать брони
       (`{:error, :draining}` из `join_or_create/create/join/join_by_id`),
       `/readyz` начинает отвечать 503.
    2. Всем живым комнатам уходит закрытие с кодом **4001 «server shutdown»** —
       клиенты получают `onLeave(4001)` и знают, что это плановое закрытие,
       а не обрыв сети. Комнаты останавливаются.
    3. Drain ждёт опустешения реестра комнат (не дольше
       `config :ex_games, :drain_timeout_ms`, по умолчанию 10 секунд);
       остатки добивает остановка supervision tree (`terminate/2` комнат
       тоже шлёт 4001).
  """

  use GenServer

  @default_timeout 10_000

  @doc false
  def start_link(_arg), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]), do: {:ok, %{draining: false}}

  @doc """
  Опустошает ноду (идемпотентно): флаг + закрытие комнат — мгновенно,
  ожидание опустошения реестра — не дольше `timeout` мс (по умолчанию
  `config :ex_games, :drain_timeout_ms`). Блокирует вызывающий процесс.
  """
  @spec drain(non_neg_integer() | nil) :: :ok
  def drain(timeout \\ nil) do
    GenServer.call(__MODULE__, :drain)
    wait_rooms_empty(deadline(timeout))
    :ok
  end

  @doc "Нода сливает трафик? (readiness-проба и проверка матчмейкера)."
  @spec draining?() :: boolean()
  def draining?, do: GenServer.call(__MODULE__, :draining?)

  @doc "Сброс флага (тестовый хук — в бою опустошённая нода не возвращается)."
  @spec reset() :: :ok
  def reset, do: GenServer.cast(__MODULE__, :reset)

  @impl true
  def handle_call(:drain, _from, %{draining: false} = state) do
    # флаг до sweep'а: /readyz и матчмейкер закрываются сразу,
    # отвечаем не дожидаясь остановки комнат (ожидание — в drain/1)
    Enum.each(room_pids(), &GenServer.cast(&1, :drain_dispose))
    {:reply, :ok, %{state | draining: true}}
  end

  def handle_call(:drain, _from, %{draining: true} = state), do: {:reply, :ok, state}

  def handle_call(:draining?, _from, state), do: {:reply, state.draining, state}

  @impl true
  def handle_cast(:reset, state), do: {:noreply, %{state | draining: false}}

  # -------------------------------------------------------------------------
  # Внутреннее
  # -------------------------------------------------------------------------

  defp room_pids do
    Registry.select(ExGames.RoomRegistry, [{{{:room, :_}, :"$1", :_}, [], [:"$1"]}])
  end

  defp deadline(nil), do: deadline(drain_timeout())
  defp deadline(ms) when is_integer(ms), do: System.monotonic_time(:millisecond) + ms

  defp wait_rooms_empty(deadline) do
    if Registry.count(ExGames.RoomRegistry) == 0 do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        # таймаут: остановка supervision tree добьёт остатки (terminate шлёт 4001)
        :ok
      else
        Process.sleep(20)
        wait_rooms_empty(deadline)
      end
    end
  end

  defp drain_timeout, do: Application.get_env(:ex_games, :drain_timeout_ms, @default_timeout)
end
