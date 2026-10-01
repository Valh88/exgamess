defmodule ExGames.Telemetry do
  @sample_ms 10_000

  @moduledoc """
  Агрегатор доменных метрик ExGames поверх `:telemetry` — без внешних
  зависимостей (ETS + сэмплер в одном GenServer).

  Обработчик (элемент дерева супервизии `ExGames.Application`) слушает все
  события с префиксом `[:ex_games]` и копит:

    * **счётчики** — по полному пути события (`ex_games.room.join`);
    * **gauge'и «последнее значение»** — по числовым измерениям события
      (`[:ex_games, :room, :ping]` c `%{rtt: …}` → `room.ping.rtt`).

  Каждые #{@sample_ms} мс сэмплер записывает gauge'и ноды: живые комнаты
  (Registry), клиенты в комнатах (сумма листингов), онлайн (Presence),
  память и число процессов BEAM.

  Чтение — `snapshot/0` (map для админ-панели) и `prometheus/0`
  (текстовый формат Prometheus для `/metrics` в ex_games_web).

  ## События домена

    * `[:ex_games, :room, :created | :disposed | :join | :rejoin | :leave | :kick]`
    * `[:ex_games, :room, :message]` — count + duration_ms обработки кадра
    * `[:ex_games, :room, :ping]` — rtt клиента
    * `[:ex_games, :room, :set_state]` / `[:ex_games, :room, :set_state_rejected]`
      — применённые и отклонённые гейтом схемы документы состояния
    * `[:ex_games, :room, :logic_lua_call]` — count + duration_ms вызова скрипта
    * `[:ex_games, :room, :logic_lua_error | :logic_lua_unknown_effect]`
    * `[:ex_games, :logic, :started]`, `[:ex_games, :queue, :matched]`,
      `[:ex_games, :matchmaker, :room_gone]`
  """

  use GenServer

  @table :ex_games_telemetry
  @handler __MODULE__
  @sample_ms 10_000

  # :telemetry диспетчеризует только по ПОЛНЫМ именам событий (префиксной
  # привязки нет) — обработчик подписан на каждый доменный звук явно.
  # Новое событие добавляйте сюда (и в moduledoc), иначе агрегатор его не увидит.
  @event_names [
    [:ex_games, :room, :created],
    [:ex_games, :room, :disposed],
    [:ex_games, :room, :join],
    [:ex_games, :room, :rejoin],
    [:ex_games, :room, :leave],
    [:ex_games, :room, :kick],
    [:ex_games, :room, :message],
    [:ex_games, :room, :ping],
    [:ex_games, :room, :set_state],
    [:ex_games, :room, :set_state_rejected],
    [:ex_games, :room, :logic_lua_call],
    [:ex_games, :room, :logic_lua_error],
    [:ex_games, :room, :logic_lua_unknown_effect],
    [:ex_games, :logic, :started],
    [:ex_games, :queue, :matched],
    [:ex_games, :matchmaker, :room_gone]
  ]

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Счётчики и gauge'и: `%{\"room.join\" => 3, …}` / `%{\"node.rooms_active\" => 2.0, …}`."
  @spec snapshot() :: %{counters: %{String.t() => number()}, gauges: %{String.t() => number()}}
  def snapshot, do: %{counters: counters(), gauges: gauges()}

  @doc "Текстовый формат Prometheus (для GET /metrics)."
  @spec prometheus() :: String.t()
  def prometheus do
    counters =
      Enum.map(counters(), fn {name, value} ->
        metric = prometheus_name(name) <> "_total"
        ["# TYPE #{metric} counter\n#{metric} #{value}\n"]
      end)

    gauges =
      Enum.map(gauges(), fn {name, value} ->
        metric = prometheus_name(name)
        ["# TYPE #{metric} gauge\n#{metric} #{format_value(value)}\n"]
      end)

    IO.iodata_to_binary(counters ++ gauges)
  end

  # -------------------------------------------------------------------------
  # Обработчик телеметрии (публичный — зовёт :telemetry)
  # -------------------------------------------------------------------------

  @doc false
  def handle_event([:ex_games | rest], measurements, _metadata, _config) when rest != [] do
    # таблица исчезает при остановке агрегатора (останов ноды) раньше, чем
    # detached обработчик — пропущенный инкремент не стоит падения вызывателя
    try do
      counter_key = {:counter, rest}
      :ets.update_counter(@table, counter_key, {2, 1}, {counter_key, 0})

      Enum.each(measurements, fn
        {name, value} when is_number(value) ->
          :ets.insert(@table, {{:gauge, gauge_name(rest, name)}, value})

        _ ->
          :ok
      end)

      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # -------------------------------------------------------------------------
  # Сэмплер gauge'ов ноды
  # -------------------------------------------------------------------------

  @doc false
  def sample do
    gauges = %{
      "node.rooms_active" => ExGames.Rooms.count(),
      "node.clients_in_rooms" => clients_in_rooms(),
      "node.online" => map_size(ExGames.Presence.list_online()),
      "node.memory_bytes" => :erlang.memory(:total),
      "node.process_count" => :erlang.system_info(:process_count)
    }

    Enum.each(gauges, fn {name, value} ->
      try do
        :ets.insert(@table, {{:gauge, name}, value})
      rescue
        ArgumentError -> :ok
      end
    end)

    gauges
  end

  # -------------------------------------------------------------------------

  @impl true
  def init(_arg) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    # detach идемпотентен: перезапуск GenServer не роняет init на повторном attach
    :telemetry.detach(@handler)
    :telemetry.attach_many(@handler, @event_names, &__MODULE__.handle_event/4, nil)
    schedule_sample()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sample, state) do
    sample()
    schedule_sample()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(@handler)

  defp schedule_sample, do: Process.send_after(self(), :sample, @sample_ms)

  defp counters do
    @table
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn
      {{:counter, path}, value}, acc -> Map.put(acc, Enum.join(path, "."), value)
      _, acc -> acc
    end)
  end

  defp gauges do
    @table
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn
      {{:gauge, name}, value}, acc when is_number(value) -> Map.put(acc, name, value)
      _, acc -> acc
    end)
  end

  defp gauge_name(path, measurement), do: Enum.map_join(path ++ [measurement], ".", &to_string/1)

  defp clients_in_rooms do
    ExGames.Matchmaker.all_listings()
    |> Enum.map(& &1.clients)
    |> Enum.sum()
  end

  defp prometheus_name(name), do: "ex_games_" <> String.replace(name, ".", "_")

  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: Float.to_string(value)
end
