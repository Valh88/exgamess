defmodule ExGames.Room.Server do
  @moduledoc """
  GenServer комнаты: брони мест, lifecycle-колбэки игрового модуля,
  тик, rate-limit, авто-закрытие.

  Транспорт (WebSocket-обработчик в веб-приложении) взаимодействует
  с сервером комнаты через API:

    * `reserve_seat/5` — бронь места (двухфазный join, шаг 1);
    * `attach/4` — подключение транспорта к забронированному месту (шаг 2);
    * `client_frame/3` — входящий кадр от клиента;
    * `detach/2` — согласованное отключение.

  Кадры пушатся транспорту сообщением `{:ex_games_push, frame}`, закрытие —
  `{:ex_games_closed, code, message}`. Коды закрытия — как в Colyseus:
  4000 — нормальное закрытие, 4001 — выключение сервера, 4002 — ошибка/кик.
  """

  use GenServer

  alias ExGames.Id
  alias ExGames.Room
  alias ExGames.Room.Client
  alias ExGames.Wire

  require Logger

  @typedoc "Внутреннее состояние сервера комнаты."
  @type t :: %__MODULE__{
          room_id: Id.id(),
          module: module(),
          handle: Room.handle(),
          options: keyword(),
          max_clients: non_neg_integer() | :infinity,
          locked: boolean(),
          metadata: map(),
          clients: %{Id.id() => Client.t()},
          monitors: %{Id.id() => reference()},
          reserved: %{Id.id() => %{auth: term(), options: map(), timer: reference()}},
          rate: %{Id.id() => {non_neg_integer(), integer()}},
          game_state: term() | nil,
          state_dirty: boolean(),
          user_state: term(),
          tick_timer: reference() | nil,
          last_tick: integer()
        }

  defstruct room_id: nil,
            room_name: nil,
            module: nil,
            handle: nil,
            options: [],
            max_clients: 8,
            locked: false,
            metadata: %{},
            clients: %{},
            monitors: %{},
            reserved: %{},
            rate: %{},
            game_state: nil,
            state_dirty: false,
            user_state: nil,
            tick_timer: nil,
            last_tick: 0

  # -------------------------------------------------------------------------
  # Управление жизненным циклом
  # -------------------------------------------------------------------------

  @doc "Child spec комнаты для DynamicSupervisor."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    module = Keyword.fetch!(opts, :module)
    room_id = Keyword.get(opts, :room_id) || Id.room_id()

    %{
      id: {:room, room_id},
      start: {__MODULE__, :start_link, [module, room_id, opts]},
      restart: :temporary
    }
  end

  @doc """
  Стартует GenServer комнаты. Имя регистрируется через
  `ExGames.RoomRegistry` по ключу `{:room, room_id}`.
  """
  @spec start_link(module(), Id.id(), keyword()) :: GenServer.on_start()
  def start_link(module, room_id, opts \\ []) do
    GenServer.start_link(__MODULE__, {module, room_id, opts}, name: Room.via(room_id))
  end

  # -------------------------------------------------------------------------
  # API: брони и подключения
  # -------------------------------------------------------------------------

  @doc """
  Бронирует место в комнате (двухфазный join, шаг 1). Возвращает
  `:ok` либо `{:error, :locked | :full | :unknown_room}`. Бронь истекает
  через `ttl` мс (по умолчанию 15 секунд, как в Colyseus).
  """
  @spec reserve_seat(Id.id(), Id.id(), term(), map(), non_neg_integer() | :default) ::
          :ok | {:error, :locked | :full | :unknown_room}
  def reserve_seat(room_id, session_id, auth_data, options, ttl \\ :default) do
    ttl = if ttl == :default, do: 15_000, else: ttl
    GenServer.call(via(room_id), {:reserve_seat, session_id, auth_data, options, ttl})
  catch
    :exit, _ -> {:error, :unknown_room}
  end

  @doc """
  Подключает процесс транспорта `pid` к забронированному месту (шаг 2).
  Возвращает `{:ok, join_frame, state_frame | nil}` либо
  `{:error, :no_reservation | :full | :unknown_room}`.
  """
  @spec attach(Id.id(), Id.id(), pid(), map()) ::
          {:ok, Wire.frame(), Wire.frame() | nil} | {:error, term()}
  def attach(room_id, session_id, pid, options \\ %{}) do
    GenServer.call(via(room_id), {:attach, session_id, pid, options})
  catch
    :exit, _ -> {:error, :unknown_room}
  end

  @doc "Передаёт в комнату сырой кадр от клиента."
  @spec client_frame(Id.id(), Id.id(), Wire.frame()) :: :ok
  def client_frame(room_id, session_id, frame) do
    GenServer.cast(via(room_id), {:client_frame, session_id, frame})
  rescue
    _ -> :ok
  end

  @doc "Клиент закрыл соединение по своей инициативе."
  @spec detach(Id.id(), Id.id()) :: :ok
  def detach(room_id, session_id) do
    GenServer.cast(via(room_id), {:client_left, session_id, :leave})
  rescue
    _ -> :ok
  end

  @doc "Явно закрывает комнату (клиентам уходит 4000)."
  @spec dispose(Id.id()) :: :ok
  def dispose(room_id), do: GenServer.cast(via(room_id), :dispose)

  @doc "Снимок листинга комнаты (для матчмейкера и лобби)."
  @spec listing(Id.id()) ::
          {:ok,
           %{
             room_id: Id.id(),
             module: module(),
             clients: non_neg_integer(),
             max_clients: non_neg_integer() | :infinity,
             locked: boolean(),
             metadata: map()
           }}
          | {:error, :unknown_room}
  def listing(room_id) do
    GenServer.call(via(room_id), :listing)
  catch
    :exit, _ -> {:error, :unknown_room}
  end

  defp via(room_id), do: Room.via(room_id)

  # -------------------------------------------------------------------------
  # Callbacks
  # -------------------------------------------------------------------------

  @impl true
  def init({module, room_id, opts}) do
    options = Keyword.merge(module.__room_options__(), opts)
    handle = %Room.Handle{room_id: room_id}

    case module.room_init(Keyword.get(opts, :options, %{}), handle) do
      {:ok, user_state} ->
        create_options = Keyword.get(opts, :options, %{})

        state = %__MODULE__{
          room_id: room_id,
          room_name: Keyword.get(opts, :room_name),
          module: module,
          handle: handle,
          options: options,
          max_clients: Keyword.get(options, :max_clients, 8),
          # create-опции (в т.ч. filter_by-ключи) — публичные метаданные листинга
          metadata: create_options,
          user_state: user_state,
          last_tick: System.monotonic_time(:millisecond)
        }

        publish_listing(state)
        :telemetry.execute([:ex_games, :room, :created], %{}, %{room_id: room_id, module: module})
        {:ok, arm_tick(state)}

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:reserve_seat, session_id, auth_data, options, ttl}, _from, %__MODULE__{} = state) do
    cond do
      state.locked ->
        {:reply, {:error, :locked}, state}

      full?(state) ->
        {:reply, {:error, :full}, state}

      true ->
        timer = Process.send_after(self(), {:seat_expired, session_id}, ttl)

        reserved =
          Map.put(state.reserved, session_id, %{auth: auth_data, options: options, timer: timer})

        state = %__MODULE__{state | reserved: reserved}
        publish_listing(state)
        {:reply, :ok, state}
    end
  end

  def handle_call({:attach, session_id, pid, _options}, _from, %__MODULE__{} = state) do
    {seat, reserved} = Map.pop(state.reserved, session_id)

    cond do
      is_nil(seat) ->
        {:reply, {:error, :no_reservation}, state}

      true ->
        # бронь изъята до проверки заполненности — иначе место учитывалось бы дважды
        state = %__MODULE__{state | reserved: reserved}

        if full?(state) do
          {:reply, {:error, :full}, state}
        else
          Process.cancel_timer(seat.timer)

          client = %Client{
            session_id: session_id,
            pid: pid,
            auth: seat.auth,
            joined_at: DateTime.utc_now()
          }

          case invoke_join(state, client, seat.auth) do
            {:ok, state} ->
              ref = Process.monitor(pid)

              state = %__MODULE__{
                state
                | clients: Map.put(state.clients, session_id, client),
                  monitors: Map.put(state.monitors, session_id, ref)
              }

              join_frame =
                Wire.encode(:join_room, %{"room_id" => state.room_id, "session_id" => session_id})

              push(pid, join_frame)
              state_frame = push_state_snapshot(pid, state)

              publish_listing(state)
              :telemetry.execute([:ex_games, :room, :join], %{count: map_size(state.clients)}, %{
                room_id: state.room_id,
                module: state.module
              })

              {:reply, {:ok, join_frame, state_frame}, state}

            {:stop, reason, state} ->
              push(pid, Wire.encode(:error, %{code: 523, message: "join rejected"}))
              push_close(pid, 4002, "join rejected")
              {:stop, {:shutdown, {:join_rejected, session_id, reason}}, state}
          end
        end
    end
  end

  def handle_call(:listing, _from, %__MODULE__{} = state) do
    {:reply,
     {:ok,
      %{
        room_id: state.room_id,
        module: state.module,
        clients: map_size(state.clients) + map_size(state.reserved),
        max_clients: state.max_clients,
        locked: state.locked,
        metadata: state.metadata
      }}, state}
  end

  def handle_call(:list_clients, _from, %__MODULE__{} = state),
    do: {:reply, Map.keys(state.clients), state}

  def handle_call(:client_count, _from, %__MODULE__{} = state),
    do: {:reply, map_size(state.clients), state}

  @impl true
  def handle_cast({:client_frame, session_id, frame}, state) do
    case Map.get(state.clients, session_id) do
      nil ->
        {:noreply, state}

      client ->
        case allow?(state, session_id) do
          {:ok, state} -> handle_frame(state, client, frame)
          :exceeded -> remove_client(state, client, :kick, 4002, "rate limit exceeded")
        end
    end
  end

  def handle_cast({:broadcast, type, payload}, state) do
    frame = Wire.encode(:room_data, {type, ExGames.Serialization.to_wire(payload)})

    state.clients
    |> Map.values()
    |> Enum.each(&push(&1.pid, frame))

    {:noreply, state}
  end

  def handle_cast({:send_to, session_id, type, payload}, state) do
    case Map.get(state.clients, session_id) do
      nil ->
        :ok

      client ->
        frame = Wire.encode(:room_data, {type, ExGames.Serialization.to_wire(payload)})
        push(client.pid, frame)
    end

    {:noreply, state}
  end

  def handle_cast({:kick, session_id}, state) do
    case Map.get(state.clients, session_id) do
      nil -> {:noreply, state}
      client -> remove_client(state, client, :kick, 4002, "kicked")
    end
  end

  def handle_cast(:lock, %__MODULE__{} = state) do
    state = %__MODULE__{state | locked: true}
    publish_listing(state)
    {:noreply, state}
  end

  def handle_cast(:unlock, %__MODULE__{} = state) do
    state = %__MODULE__{state | locked: false}
    publish_listing(state)
    {:noreply, state}
  end

  def handle_cast({:set_metadata, metadata}, %__MODULE__{} = state) do
    state = %__MODULE__{state | metadata: Map.merge(state.metadata, metadata)}
    publish_listing(state)
    {:noreply, state}
  end

  def handle_cast({:set_state, wire_state}, %__MODULE__{} = state),
    do: {:noreply, %__MODULE__{state | game_state: wire_state, state_dirty: true}}

  def handle_cast({:client_left, session_id, reason}, state) do
    case Map.get(state.clients, session_id) do
      nil -> {:noreply, state}
      client -> remove_client(state, client, reason, 4000, "client left")
    end
  end

  def handle_cast(:dispose, state) do
    close_all(state, 4000, "room closed")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, exit_reason}, state) do
    case Enum.find(state.monitors, fn {_sid, r} -> r == ref end) do
      {session_id, _} ->
        client = Map.fetch!(state.clients, session_id)
        reason = if exit_reason in [:normal, :shutdown], do: :closed, else: :crashed
        remove_client(state, client, reason, 4000, "transport closed")

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:tick, %__MODULE__{} = state) do
    elapsed = System.monotonic_time(:millisecond) - state.last_tick
    state = %__MODULE__{state | last_tick: System.monotonic_time(:millisecond)}

    case invoke_tick(state, elapsed) do
      {:ok, state} ->
        {:noreply, arm_tick(broadcast_state_if_dirty(state))}

      {:noreply, state} ->
        {:noreply, arm_tick(broadcast_state_if_dirty(state))}

      {:stop, reason, state} ->
        close_all(state, 4002, "room stopped")
        {:stop, {:shutdown, reason}, state}
    end
  end

  def handle_info({:seat_expired, session_id}, %__MODULE__{} = state) do
    {seat, reserved} = Map.pop(state.reserved, session_id)

    if seat, do: Process.cancel_timer(seat.timer)

    state = %__MODULE__{state | reserved: reserved}
    publish_listing(state)
    {:noreply, state}
  end

  def handle_info(msg, %__MODULE__{} = state) do
    case safe_apply(state.module, :handle_info, [msg, state.user_state]) do
      {:ok, {:ok, user_state}} -> {:noreply, %__MODULE__{state | user_state: user_state}}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    close_all(state, 4001, "server shutdown")
    :ets.delete(:ex_games_matchmaker_rooms, state.room_id)
    :telemetry.execute([:ex_games, :room, :disposed], %{}, %{room_id: state.room_id})

    _ = safe_apply(state.module, :room_terminate, [reason, state.user_state])
    :ok
  end

  # -------------------------------------------------------------------------
  # Внутреннее
  # -------------------------------------------------------------------------

  defp full?(%__MODULE__{max_clients: :infinity}), do: false

  defp full?(state),
    do: map_size(state.clients) + map_size(state.reserved) >= state.max_clients

  defp invoke_join(%__MODULE__{} = state, client, auth) do
    case safe_apply(state.module, :handle_join, [state.handle, client, auth, state.user_state]) do
      {:ok, {:ok, user_state}} ->
        {:ok, %__MODULE__{state | user_state: user_state}}

      {:ok, {:stop, reason, user_state}} ->
        {:stop, reason, %__MODULE__{state | user_state: user_state}}

      {:raise, exception, stacktrace} ->
        log_callback_error(state, :handle_join, exception, stacktrace)
        {:stop, exception, state}

      :callback_missing ->
        {:ok, state}
    end
  end

  defp invoke_tick(%__MODULE__{} = state, elapsed) do
    case safe_apply(state.module, :handle_tick, [elapsed, state.user_state]) do
      {:ok, {:ok, user_state}} ->
        {:ok, %__MODULE__{state | user_state: user_state}}

      {:ok, {:stop, reason, user_state}} ->
        {:stop, reason, %__MODULE__{state | user_state: user_state}}

      {:raise, exception, stacktrace} ->
        log_callback_error(state, :handle_tick, exception, stacktrace)
        {:stop, exception, state}

      :callback_missing ->
        {:noreply, state}
    end
  end

  defp handle_frame(%__MODULE__{} = state, client, frame) do
    case Wire.decode(frame) do
      {:ok, {:ping}} ->
        push(client.pid, Wire.encode(:ping))
        {:noreply, state}

      {:ok, {:room_data, type, payload}} ->
        dispatch_message(state, client, type, payload)

      {:ok, {:room_request, request_id, type, payload}} ->
        dispatch_request(state, client, request_id, type, payload)

      {:ok, {:leave_room}} ->
        remove_client(state, client, :leave, 4000, "client left")

      {:ok, {:join_room, _options}} ->
        # повторное рукопожатие после attach — игнорируем
        {:noreply, state}

      {:error, :invalid_frame} ->
        Logger.warning("[ex_games] invalid frame from #{client.session_id} in #{state.room_id}")
        remove_client(state, client, :kick, 4002, "invalid frame")
    end
  end

  defp dispatch_message(%__MODULE__{} = state, client, type, payload) do
    :telemetry.execute([:ex_games, :room, :message], %{count: 1}, %{room_id: state.room_id})

    case safe_apply(state.module, :handle_message, [
           state.handle,
           client,
           type,
           payload,
           state.user_state
         ]) do
      {:ok, {:ok, user_state}} ->
        {:noreply, %__MODULE__{state | user_state: user_state}}

      {:ok, {:stop, reason, user_state}} ->
        close_all(%__MODULE__{state | user_state: user_state}, 4002, "room stopped")
        {:stop, {:shutdown, reason}, %__MODULE__{state | user_state: user_state}}

      {:raise, exception, stacktrace} ->
        log_callback_error(state, :handle_message, exception, stacktrace)
        {:noreply, state}

      :callback_missing ->
        Logger.warning(
          "[ex_games] unhandled message #{inspect(type)} in #{state.room_id} (no clause)"
        )

        {:noreply, state}
    end
  end

  defp dispatch_request(%__MODULE__{} = state, client, request_id, type, payload) do
    case safe_apply(state.module, :handle_request, [
           state.handle,
           client,
           request_id,
           type,
           payload,
           state.user_state
         ]) do
      {:ok, {:reply, reply, user_state}} ->
        frame =
          Wire.encode(:room_response, {request_id, ExGames.Serialization.to_wire(reply)})

        push(client.pid, frame)
        {:noreply, %__MODULE__{state | user_state: user_state}}

      {:ok, {:ok, user_state}} ->
        {:noreply, %__MODULE__{state | user_state: user_state}}

      {:ok, {:error, reason, user_state}} ->
        message = if is_binary(reason), do: reason, else: inspect(reason)
        push(client.pid, Wire.encode(:error, %{code: 526, message: message}))
        {:noreply, %__MODULE__{state | user_state: user_state}}

      {:raise, exception, stacktrace} ->
        log_callback_error(state, :handle_request, exception, stacktrace)
        push(client.pid, Wire.encode(:error, %{code: 526, message: "internal error"}))
        {:noreply, state}

      :callback_missing ->
        push(client.pid, Wire.encode(:error, %{code: 526, message: "unknown request"}))
        {:noreply, state}
    end
  end

  defp remove_client(%__MODULE__{} = state, client, reason, close_code, message) do
    state =
      case Map.pop(state.monitors, client.session_id) do
        {nil, _} ->
          state

        {ref, monitors} ->
          Process.demonitor(ref, [:flush])
          %__MODULE__{state | monitors: monitors}
      end

    state = %__MODULE__{
      state
      | clients: Map.delete(state.clients, client.session_id),
        rate: Map.delete(state.rate, client.session_id)
    }

    push_close(client.pid, close_code, message)

    state =
      case safe_apply(state.module, :handle_leave, [
             state.handle,
             client,
             reason,
             state.user_state
           ]) do
        {:ok, {:ok, user_state}} -> %__MODULE__{state | user_state: user_state}
        _ -> state
      end

    publish_listing(state)
    :telemetry.execute([:ex_games, :room, :leave], %{count: map_size(state.clients)}, %{
      room_id: state.room_id,
      module: state.module
    })

    auto_dispose(state)
  end

  # Colyseus-поведение: комната без клиентов и без броней закрывается.
  defp auto_dispose(state) do
    auto? = Keyword.get(state.options, :auto_dispose, true)

    if auto? and map_size(state.clients) == 0 and map_size(state.reserved) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp allow?(%__MODULE__{} = state, session_id) do
    limit = Keyword.get(state.options, :rate_limit, 120)
    now = System.system_time(:second)
    {count, second} = Map.get(state.rate, session_id, {0, now})

    cond do
      second != now ->
        {:ok, %__MODULE__{state | rate: Map.put(state.rate, session_id, {1, now})}}

      count + 1 > limit ->
        :exceeded

      true ->
        {:ok, %__MODULE__{state | rate: Map.put(state.rate, session_id, {count + 1, now})}}
    end
  end

  defp arm_tick(%__MODULE__{} = state) do
    if state.tick_timer, do: Process.cancel_timer(state.tick_timer)

    case Keyword.get(state.options, :patch_rate, 50) do
      rate when is_integer(rate) and rate > 0 ->
        %__MODULE__{state | tick_timer: Process.send_after(self(), :tick, rate)}

      _ ->
        %__MODULE__{state | tick_timer: nil}
    end
  end

  defp push_state_snapshot(pid, state)
  defp push_state_snapshot(_pid, %__MODULE__{game_state: nil}), do: nil

  defp push_state_snapshot(pid, %__MODULE__{game_state: game_state}) do
    frame = Wire.encode(:room_state, game_state)
    push(pid, frame)
    frame
  end

  defp broadcast_state_if_dirty(%__MODULE__{state_dirty: true, game_state: game_state} = state)
       when not is_nil(game_state) do
    frame = Wire.encode(:room_state, game_state)

    state.clients
    |> Map.values()
    |> Enum.each(&push(&1.pid, frame))

    %__MODULE__{state | state_dirty: false}
  end

  defp broadcast_state_if_dirty(state), do: state

  defp push(pid, frame) when is_pid(pid), do: send(pid, {:ex_games_push, frame})
  defp push(_pid, _frame), do: :ok

  defp push_close(pid, code, message), do: send(pid, {:ex_games_closed, code, message})

  # Публикует листинг комнаты в ETS матчмейкера (только для комнат, созданных
  # через матчмейкер — у прочих room_name == nil). Вызывается из процесса
  # комнаты; ETS-запись вместо GenServer.call — без риска self-call.
  defp publish_listing(%__MODULE__{room_name: nil}), do: :ok

  defp publish_listing(%__MODULE__{} = state) do
    listing = %{
      room_id: state.room_id,
      room_name: state.room_name,
      clients: map_size(state.clients) + map_size(state.reserved),
      max_clients: state.max_clients,
      locked: state.locked,
      metadata: state.metadata
    }

    :ets.insert(:ex_games_matchmaker_rooms, {state.room_id, listing})
    :ok
  end

  defp close_all(%__MODULE__{} = state, code, message) do
    state.clients
    |> Map.values()
    |> Enum.each(fn client ->
      push_close(client.pid, code, message)
      Process.demonitor(Map.get(state.monitors, client.session_id), [:flush])
    end)
  end

  # Вызов колбэка игрового модуля; отсутствие опционального колбэка — не ошибка.
  defp safe_apply(module, fun, args) do
    if function_exported?(module, fun, length(args)) do
      try do
        {:ok, apply(module, fun, args)}
      rescue
        exception -> {:raise, exception, __STACKTRACE__}
      end
    else
      :callback_missing
    end
  end

  defp log_callback_error(state, name, exception, stacktrace) do
    Logger.error(
      "[ex_games] #{state.module}.#{name}/… raised in room #{state.room_id}: " <>
        Exception.format(:error, exception, stacktrace)
    )
  end
end
