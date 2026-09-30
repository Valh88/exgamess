defmodule ExGames.Room.Server do
  @moduledoc """
  GenServer комнаты: брони мест, lifecycle-колбэки игрового модуля,
  тик, rate-limit, авто-закрытие.

  Транспорт (WebSocket-обработчик в веб-приложении) взаимодействует
  с сервером комнаты через API:

    * `reserve_seat/5` — бронь места (двухфазный join, шаг 1);
    * `attach/4` — подключение транспорта к забронированному месту (шаг 2);
    * `client_frame/3` — входящий кадр от клиента;
    * `detach/2` — согласованное отключение;
    * `drop/2` — не-согласованный обрыв транспорта (клиент попадает в слот
      reconnection на `:reconnect_ttl`, по умолчанию 30 секунд);
    * `reattach/4` — повторное подключение транспорта по `reconnection_token`
      (без повторного join в логиках);
    * `reconnect/3` — проверка reconnection-токена (HTTP-шаг reconnect-флоу).

  Кадры пушатся транспорту сообщением `{:ex_games_push, frame}`, закрытие —
  `{:ex_games_closed, code, message}`. Коды закрытия — как в Colyseus:
  4000 — нормальное закрытие, 4001 — выключение сервера, 4002 — ошибка/кик.
  """

  # trap_exit: Rooms.stop шлёт Process.exit({:shutdown, :dispose}) — без
  # trapping terminate/2 (close_all, unpublish_listing, logic_terminate,
  # room_terminate) не вызывался бы вовсе; родительский shutdown OTP
  # обрабатывает штатно.
  use GenServer, trap_exit: true

  alias ExGames.Id
  alias ExGames.Room
  alias ExGames.Room.Client
  alias ExGames.Room.StateDiff
  alias ExGames.Wire

  require Logger

  @reconnect_ttl 30_000

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
          reconnecting: %{Id.id() => {Id.id(), reference()}},
          rate: %{Id.id() => {non_neg_integer(), integer()}},
          game_state: term() | nil,
          state_dirty: boolean(),
          last_sent_state: term() | nil,
          user_state: term(),
          logics: [{module(), term()}],
          tick_timer: reference() | nil,
          last_tick: integer(),
          timers: %{term() => reference()},
          dispose_timer: reference() | nil,
          created_at: DateTime.t() | nil
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
            reconnecting: %{},
            rate: %{},
            game_state: nil,
            state_dirty: false,
            last_sent_state: nil,
            user_state: nil,
            logics: [],
            tick_timer: nil,
            last_tick: 0,
            # Room clock: расписание таймеров по ключам (Handle.send_after/send_interval)
            timers: %{},
            # льготное окно auto_dispose_ms (см. auto_dispose/1)
            dispose_timer: nil,
            # время создания (админ-панель: возраст комнаты)
            created_at: nil

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

  @doc """
  Возвращает транспорт клиента после не-согласованного обрыва (шаг 2
  reconnect-флоу). Токен должен совпадать со слотом reconnection; `session_id`
  клиента сохраняется, логики НЕ получают join повторно. Клиенту уходит
  `join_room` с НОВЫМ `reconnection_token` (ротация, как в Colyseus) и
  полный снапшот состояния.
  """
  @spec reattach(Id.id(), Id.id(), pid(), Id.id()) ::
          {:ok, Wire.frame(), Wire.frame() | nil} | {:error, :invalid_token | :unknown_room}
  def reattach(room_id, session_id, pid, reconnection_token) do
    GenServer.call(via(room_id), {:reattach, session_id, pid, reconnection_token})
  catch
    :exit, _ -> {:error, :unknown_room}
  end

  @doc """
  Проверяет reconnection-токен (шаг 1 reconnect-флоу, HTTP-эндпоинт
  `POST /matchmake/reconnect/:room_id`). Возвращает `{:ok, session_id}`
  либо `{:error, :invalid_token | :unknown_room}`.
  """
  @spec reconnect(Id.id(), Id.id() | nil, Id.id()) ::
          {:ok, Id.id()} | {:error, :invalid_token | :unknown_room}
  def reconnect(room_id, session_id, reconnection_token) do
    GenServer.call(via(room_id), {:reconnect, session_id, reconnection_token})
  catch
    :exit, _ -> {:error, :unknown_room}
  end

  @doc "Транспорт потерян без согласия клиента (обрыв сети, краш сокета)."
  @spec drop(Id.id(), Id.id()) :: :ok
  def drop(room_id, session_id) do
    GenServer.cast(via(room_id), {:client_left, session_id, :closed})
  rescue
    _ -> :ok
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
             metadata: map(),
             created_at: DateTime.t() | nil
           }}
          | {:error, :unknown_room}
  def listing(room_id) do
    GenServer.call(via(room_id), :listing)
  catch
    :exit, _ -> {:error, :unknown_room}
  end

  @doc "Полные данные подключённых клиентов (админ-панель)."
  @spec clients_detailed(Id.id()) :: {:ok, [Client.t()]} | {:error, :unknown_room}
  def clients_detailed(room_id) do
    GenServer.call(via(room_id), :client_details)
  catch
    :exit, _ -> {:error, :unknown_room}
  end

  @doc "Снимок синхронизируемого состояния (read-only, админ-панель)."
  @spec state_snapshot(Id.id()) :: {:ok, term() | nil} | {:error, :unknown_room}
  def state_snapshot(room_id) do
    GenServer.call(via(room_id), :state_snapshot)
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

        # модули логики видят create-опции (runtime) поверх compile-time
        # опций `use ExGames.Room` (напр. lua_script моста)
        logic_options =
          module.__room_options__()
          |> Keyword.merge(opts)
          |> Map.new()
          |> Map.merge(create_options)

        case init_logics(Keyword.get(options, :logic, []), logic_options, handle, []) do
          {:ok, logics} ->
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
              logics: logics,
              last_tick: System.monotonic_time(:millisecond),
              created_at: DateTime.utc_now() |> DateTime.truncate(:second)
            }

            publish_listing(state)

            :telemetry.execute([:ex_games, :room, :created], %{}, %{
              room_id: room_id,
              module: module
            })

            {:ok, arm_tick(state)}

          {:stop, reason} ->
            {:stop, reason}
        end

      {:stop, reason} ->
        {:stop, reason}
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
            reconnection_token: Id.token(),
            joined_at: DateTime.utc_now()
          }

          case invoke_join(state, client, seat.auth) do
            {:ok, %__MODULE__{} = state} ->
              case run_logic_join(state, client, seat.auth) do
                {:ok, %__MODULE__{} = state} ->
                  # неотправленный дифф уходит текущим клиентам ДО присоединения
                  # новичка (тот получит полный снапшот актуального состояния)
                  state = flush_state_delta(state)

                  ref = Process.monitor(pid)

                  state =
                    %__MODULE__{
                      state
                      | clients: Map.put(state.clients, session_id, client),
                        monitors: Map.put(state.monitors, session_id, ref)
                    }
                    |> cancel_dispose_timer()

                  join_frame =
                    Wire.encode(:join_room, %{
                      "room_id" => state.room_id,
                      "session_id" => session_id,
                      "reconnection_token" => client.reconnection_token
                    })

                  push(pid, join_frame)
                  state_frame = push_state_snapshot(pid, state)
                  state = %__MODULE__{state | last_sent_state: state.game_state}

                  track_presence(state, client)
                  publish_listing(state)

                  :telemetry.execute(
                    [:ex_games, :room, :join],
                    %{count: map_size(state.clients)},
                    %{
                      room_id: state.room_id,
                      module: state.module
                    }
                  )

                  {:reply, {:ok, join_frame, state_frame}, state}

                {:stop, reason, %__MODULE__{} = state} ->
                  push(pid, Wire.encode(:error, %{code: 523, message: "join rejected"}))
                  push_close(pid, 4002, "join rejected")
                  {:stop, {:shutdown, {:join_rejected, session_id, reason}}, state}
              end

            {:stop, reason, %__MODULE__{} = state} ->
              push(pid, Wire.encode(:error, %{code: 523, message: "join rejected"}))
              push_close(pid, 4002, "join rejected")
              {:stop, {:shutdown, {:join_rejected, session_id, reason}}, state}
          end
        end
    end
  end

  def handle_call({:reattach, session_id, pid, token}, _from, %__MODULE__{} = state) do
    case Map.pop(state.reconnecting, token) do
      {nil, _} ->
        {:reply, {:error, :invalid_token}, state}

      {{slot_session_id, timer}, reconnecting} when slot_session_id != session_id ->
        # чужой session_id — слот возвращаем на место
        {:reply, {:error, :invalid_token},
         %__MODULE__{state | reconnecting: Map.put(reconnecting, token, {slot_session_id, timer})}}

      {{^session_id, timer}, reconnecting} ->
        Process.cancel_timer(timer)

        case Map.fetch(state.clients, session_id) do
          :error ->
            {:reply, {:error, :invalid_token}, %__MODULE__{state | reconnecting: reconnecting}}

          {:ok, %Client{} = client} ->
            # подмена транспорта: старый монитор демонтируем, логики не трогаем
            state = drop_monitor(state, session_id)
            state = flush_state_delta(state)
            ref = Process.monitor(pid)

            # ротация токена (как в Colyseus): каждое переподключение получает новый
            client = %Client{client | pid: pid, reconnection_token: Id.token()}

            state = %__MODULE__{
              state
              | reconnecting: reconnecting,
                clients: Map.put(state.clients, session_id, client),
                monitors: Map.put(state.monitors, session_id, ref)
            }

            join_frame =
              Wire.encode(:join_room, %{
                "room_id" => state.room_id,
                "session_id" => session_id,
                "reconnection_token" => client.reconnection_token
              })

            push(pid, join_frame)
            state_frame = push_state_snapshot(pid, state)
            state = %__MODULE__{state | last_sent_state: state.game_state}

            :telemetry.execute([:ex_games, :room, :rejoin], %{count: map_size(state.clients)}, %{
              room_id: state.room_id,
              module: state.module
            })

            {:reply, {:ok, join_frame, state_frame}, state}
        end
    end
  end

  def handle_call({:reconnect, session_id, token}, _from, %__MODULE__{} = state) do
    case Map.get(state.reconnecting, token) do
      {slot_session_id, _timer} when is_nil(session_id) or slot_session_id == session_id ->
        {:reply, {:ok, slot_session_id}, state}

      _ ->
        {:reply, {:error, :invalid_token}, state}
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
        metadata: state.metadata,
        created_at: state.created_at
      }}, state}
  end

  def handle_call(:client_details, _from, %__MODULE__{} = state),
    do: {:reply, Map.values(state.clients), state}

  def handle_call(:state_snapshot, _from, %__MODULE__{} = state),
    do: {:reply, {:ok, state.game_state}, state}

  def handle_call(:list_clients, _from, %__MODULE__{} = state),
    do: {:reply, Map.keys(state.clients), state}

  def handle_call(:client_count, _from, %__MODULE__{} = state),
    do: {:reply, map_size(state.clients), state}

  def handle_call({:client_rtt, session_id}, _from, %__MODULE__{} = state) do
    case Map.fetch(state.clients, session_id) do
      {:ok, %Client{rtt: rtt}} -> {:reply, {:ok, rtt}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(
        {:reserve_seat, session_id, auth_data, options, ttl},
        _from,
        %__MODULE__{} = state
      ) do
    cond do
      state.locked ->
        {:reply, {:error, :locked}, state}

      full?(state) ->
        {:reply, {:error, :full}, state}

      true ->
        case auth_chain(state, auth_data, options) do
          {:ok, auth} ->
            timer = Process.send_after(self(), {:seat_expired, session_id}, ttl)

            reserved =
              Map.put(state.reserved, session_id, %{auth: auth, options: options, timer: timer})

            state =
              %__MODULE__{state | reserved: reserved}
              |> cancel_dispose_timer()

            publish_listing(state)
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

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

  def handle_cast({:broadcast_except, except, type, payload}, state) do
    frame = Wire.encode(:room_data, {type, ExGames.Serialization.to_wire(payload)})
    except = MapSet.new(List.wrap(except))

    Enum.each(state.clients, fn {_sid, client} ->
      unless MapSet.member?(except, client.session_id), do: push(client.pid, frame)
    end)

    {:noreply, state}
  end

  # -------------------------------------------------------------------------
  # Room clock: управляемые таймеры (Handle.send_after/send_interval/cancel_timer)
  # -------------------------------------------------------------------------

  def handle_cast({:send_after, key, msg, ms}, %__MODULE__{} = state) do
    state = cancel_timer(state, key)
    timer = Process.send_after(self(), {:ex_games_timer, key, msg}, ms)
    {:noreply, put_timer(state, key, timer)}
  end

  def handle_cast({:send_interval, key, msg, ms}, %__MODULE__{} = state) do
    state = cancel_timer(state, key)
    timer = Process.send_after(self(), {:ex_games_timer_fire, key, msg, ms}, ms)
    {:noreply, put_timer(state, key, timer)}
  end

  def handle_cast({:cancel_timer, key}, %__MODULE__{} = state),
    do: {:noreply, cancel_timer(state, key)}

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

  # ветка общего состояния (мульти-модули): game_state[key] = doc,
  # остальные ветки не трогаем
  def handle_cast({:set_state_branch, key, wire_doc}, %__MODULE__{} = state) do
    game_state = Map.put(state.game_state || %{}, key, wire_doc)
    {:noreply, %__MODULE__{state | game_state: game_state, state_dirty: true}}
  end

  def handle_cast({:client_left, session_id, :closed}, state) do
    case Map.get(state.clients, session_id) do
      nil -> {:noreply, state}
      client -> move_to_reconnecting(state, client, :closed)
    end
  end

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

  def handle_cast(:drain_dispose, state) do
    # плановое опустошение ноды (ExGames.Runtime.Drain): клиенты получают
    # 4001 «server shutdown» — SDK отличает плановое закрытие от обрыва
    close_all(state, 4001, "server shutdown")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _exit_reason}, state) do
    case Enum.find(state.monitors, fn {_sid, r} -> r == ref end) do
      {session_id, _} ->
        case Map.get(state.clients, session_id) do
          nil -> {:noreply, state}
          client -> move_to_reconnecting(state, client, :closed)
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:reconnect_expired, token}, %__MODULE__{} = state) do
    case Map.pop(state.reconnecting, token) do
      {nil, _} ->
        {:noreply, state}

      {{session_id, _timer}, reconnecting} ->
        state = %__MODULE__{state | reconnecting: reconnecting}

        case Map.get(state.clients, session_id) do
          nil -> {:noreply, state}
          client -> remove_client(state, client, :closed, 4000, "reconnect timeout")
        end
    end
  end

  def handle_info(:tick, %__MODULE__{} = state) do
    elapsed = System.monotonic_time(:millisecond) - state.last_tick
    state = %__MODULE__{state | last_tick: System.monotonic_time(:millisecond)}

    case invoke_tick(state, elapsed) do
      {:stop, reason, state} ->
        close_all(state, 4002, "room stopped")
        {:stop, {:shutdown, reason}, state}

      {:ok, state} ->
        case run_logic_tick(state, elapsed) do
          {:ok, state} ->
            {:noreply, arm_tick(broadcast_state_if_dirty(state))}

          {:stop, reason, state} ->
            close_all(state, 4002, "room stopped")
            {:stop, {:shutdown, reason}, state}
        end
    end
  end

  def handle_info({:seat_expired, session_id}, %__MODULE__{} = state) do
    {seat, reserved} = Map.pop(state.reserved, session_id)

    if seat, do: Process.cancel_timer(seat.timer)

    state = %__MODULE__{state | reserved: reserved}
    publish_listing(state)
    {:noreply, state}
  end

  def handle_info({:ex_games_timer, key, msg}, %__MODULE__{} = state) do
    # одноразовый таймер: уходит из расписания, доставка — в обычную цепочку
    state = %__MODULE__{state | timers: Map.delete(state.timers, key)}
    deliver_info(state, {:ex_games_timer, key, msg})
  end

  def handle_info({:ex_games_timer_fire, key, msg, ms}, %__MODULE__{} = state) do
    # повторяющийся: переармируем ДО доставки — интервал стабилен независимо
    # от длительности обработчика (остановка комнаты умрёт вместе с таймером)
    timer = Process.send_after(self(), {:ex_games_timer_fire, key, msg, ms}, ms)
    deliver_info(put_timer(state, key, timer), {:ex_games_timer, key, msg})
  end

  def handle_info(:dispose_if_empty, %__MODULE__{} = state) do
    state = %__MODULE__{state | dispose_timer: nil}

    if empty?(state) do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(msg, %__MODULE__{} = state) do
    # цепочка: комната (handle_info), затем модули логики (logic_info).
    # Сюда попадают любые сообщения процесса комнаты, кроме служебных
    # (:tick, :seat_expired, :DOWN, таймеры clock) — например, PubSub-подписки
    # и пуш от внешних процессов.
    deliver_info(state, msg)
  end

  # Доставка произвольного сообщения в цепочку handle_info → logic_info
  # (общий путь для «чужих» сообщений и таймеров Room clock).
  defp deliver_info(%__MODULE__{} = state, msg) do
    case safe_apply(state.module, :handle_info, [msg, state.user_state]) do
      {:ok, {:ok, user_state}} ->
        run_logic_info(put_user_state(state, user_state), msg)

      _ ->
        run_logic_info(state, msg)
    end
  end

  @impl true
  def terminate(reason, state) do
    Enum.each(state.timers, fn {_key, timer} -> Process.cancel_timer(timer) end)
    close_all(state, 4001, "server shutdown")
    unpublish_listing(state)
    :telemetry.execute([:ex_games, :room, :disposed], %{}, %{room_id: state.room_id})

    # цепочка логик в обратном порядке, затем сама комната
    Enum.each(Enum.reverse(state.logics), fn {mod, logic_state} ->
      _ = safe_apply(mod, :logic_terminate, [reason, logic_state])
      :ok
    end)

    _ = safe_apply(state.module, :room_terminate, [reason, state.user_state])
    :ok
  end

  # -------------------------------------------------------------------------
  # Внутреннее
  # -------------------------------------------------------------------------

  defp full?(%__MODULE__{max_clients: :infinity}), do: false

  defp full?(state),
    do: map_size(state.clients) + map_size(state.reserved) >= state.max_clients

  # Клиент-отчётный RTT: первый замер принимаем как есть, последующие
  # сглаживаем EMA α=0.25 (та же константа, что у client-side offset).
  defp store_rtt(%Client{rtt: nil} = client, rtt) when is_integer(rtt) and rtt >= 0,
    do: %Client{client | rtt: rtt}

  defp store_rtt(%Client{rtt: prev} = client, rtt)
       when is_integer(rtt) and rtt >= 0 and is_integer(prev),
       do: %Client{client | rtt: div(prev * 3 + rtt, 4)}

  defp store_rtt(client, _rtt), do: client

  defp invoke_join(%__MODULE__{} = state, client, auth) do
    case safe_apply(state.module, :handle_join, [state.handle, client, auth, state.user_state]) do
      {:ok, {:ok, user_state}} ->
        {:ok, %__MODULE__{state | user_state: user_state}}

      {:ok, {:stop, reason, user_state}} ->
        {:stop, reason, %__MODULE__{state | user_state: user_state}}

      {:raise, exception, stacktrace} ->
        log_callback_error(state.module, :handle_join, exception, stacktrace, state.room_id)
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
        log_callback_error(state.module, :handle_tick, exception, stacktrace, state.room_id)
        {:stop, exception, state}

      :callback_missing ->
        {:ok, state}
    end
  end

  defp handle_frame(%__MODULE__{} = state, client, frame) do
    case Wire.decode(frame) do
      {:ok, {:ping}} ->
        push(client.pid, Wire.encode(:ping))
        {:noreply, state}

      {:ok, {:ping, payload}} when is_map(payload) ->
        # эхо метки клиента + серверный штамп времени (unix-ms): клиент
        # оценивает смещение часов для Room.serverNow(). Клиент-отчётный
        # RTT (ms) складываем в структуру клиента — для мониторинга и
        # лаг-осознанной логики; сервер цифре доверяет (античита нет).
        client = store_rtt(client, payload["rtt"])
        state = %{state | clients: Map.put(state.clients, client.session_id, client)}

        if is_integer(client.rtt) do
          :telemetry.execute([:ex_games, :room, :ping], %{rtt: client.rtt}, %{
            room_id: state.room_id
          })
        end

        push(
          client.pid,
          Wire.encode(:ping, Map.put(payload, "ts", System.system_time(:millisecond)))
        )

        {:noreply, state}

      {:ok, {:ping, payload}} ->
        push(client.pid, Wire.encode(:ping, payload))
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

    # роутинг по объявленным типам: сначала встроенные логики, потом сама комната
    case logic_for_message(state, type) do
      {mod, logic_state} ->
        case safe_apply(mod, :handle_message, [
               state.handle,
               client,
               type,
               payload,
               logic_state
             ]) do
          {:ok, {:ok, logic_state}} ->
            {:noreply, put_logic(state, mod, logic_state)}

          {:ok, {:stop, reason, logic_state}} ->
            state = put_logic(state, mod, logic_state)
            close_all(state, 4002, "room stopped")
            {:stop, {:shutdown, reason}, state}

          {:raise, exception, stacktrace} ->
            log_callback_error(mod, :handle_message, exception, stacktrace, state.room_id)
            {:noreply, state}

          :callback_missing ->
            {:noreply, state}
        end

      nil ->
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
            log_callback_error(
              state.module,
              :handle_message,
              exception,
              stacktrace,
              state.room_id
            )

            {:noreply, state}

          :callback_missing ->
            Logger.warning(
              "[ex_games] unhandled message #{inspect(type)} in #{state.room_id} (no clause)"
            )

            {:noreply, state}
        end
    end
  end

  defp dispatch_request(%__MODULE__{} = state, client, request_id, type, payload) do
    # ошибка обработки запроса уходит с request_id: клиент мгновенно
    # отклоняет ожидающий запрос, не дожидаясь таймаута (поле опциональное —
    # обратная совместимость с прежними клиентами)
    error_frame = fn message ->
      Wire.encode(:error, %{code: 526, message: message, request_id: request_id})
    end

    case logic_for_request(state, type) do
      {mod, logic_state} ->
        case safe_apply(mod, :handle_request, [
               state.handle,
               client,
               request_id,
               type,
               payload,
               logic_state
             ]) do
          {:ok, {:reply, reply, logic_state}} ->
            frame =
              Wire.encode(:room_response, {request_id, ExGames.Serialization.to_wire(reply)})

            push(client.pid, frame)
            {:noreply, put_logic(state, mod, logic_state)}

          {:ok, {:ok, logic_state}} ->
            {:noreply, put_logic(state, mod, logic_state)}

          {:ok, {:error, reason, logic_state}} ->
            message = if is_binary(reason), do: reason, else: inspect(reason)
            push(client.pid, error_frame.(message))
            {:noreply, put_logic(state, mod, logic_state)}

          {:raise, exception, stacktrace} ->
            log_callback_error(mod, :handle_request, exception, stacktrace, state.room_id)
            push(client.pid, error_frame.("internal error"))
            {:noreply, state}

          :callback_missing ->
            push(client.pid, error_frame.("unknown request"))
            {:noreply, state}
        end

      nil ->
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
            push(client.pid, error_frame.(message))
            {:noreply, %__MODULE__{state | user_state: user_state}}

          {:raise, exception, stacktrace} ->
            log_callback_error(
              state.module,
              :handle_request,
              exception,
              stacktrace,
              state.room_id
            )

            push(client.pid, error_frame.("internal error"))
            {:noreply, state}

          :callback_missing ->
            push(client.pid, error_frame.("unknown request"))
            {:noreply, state}
        end
    end
  end

  defp remove_client(%__MODULE__{} = state, client, reason, close_code, message) do
    state = clear_reconnect_slot(state, client.session_id)
    state = drop_monitor(state, client.session_id)
    untrack_presence(state, client)

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

    state = run_logic_leave(state, client, reason)

    publish_listing(state)

    :telemetry.execute([:ex_games, :room, :leave], %{count: map_size(state.clients)}, %{
      room_id: state.room_id,
      module: state.module
    })

    auto_dispose(state)
  end

  # Colyseus-поведение: комната без клиентов и без броней закрывается.
  # auto_dispose_ms > 0 откладывает закрытие на льготное окно — таймер
  # :dispose_if_empty; новый клиент или бронь отменяют его (см. ниже),
  # при срабатывании пустота перепроверяется.
  defp auto_dispose(%__MODULE__{} = state) do
    auto? = Keyword.get(state.options, :auto_dispose, true)

    if auto? and empty?(state) do
      case Keyword.get(state.options, :auto_dispose_ms, 0) do
        ms when is_integer(ms) and ms > 0 ->
          timer = Process.send_after(self(), :dispose_if_empty, ms)
          {:noreply, %__MODULE__{state | dispose_timer: timer}}

        _ ->
          {:stop, :normal, state}
      end
    else
      {:noreply, state}
    end
  end

  defp empty?(%__MODULE__{} = state),
    do: map_size(state.clients) == 0 and map_size(state.reserved) == 0

  defp cancel_dispose_timer(%__MODULE__{dispose_timer: nil} = state), do: state

  defp cancel_dispose_timer(%__MODULE__{} = state) do
    Process.cancel_timer(state.dispose_timer)
    %__MODULE__{state | dispose_timer: nil}
  end

  # Не-согласованный обрыв: клиент остаётся в комнате (место занято), слот
  # reconnection ждёт reattach до :reconnect_ttl. Отключённая опция или
  # уже существующий слот → обычное удаление / no-op.
  defp move_to_reconnecting(%__MODULE__{} = state, client, reason) do
    state = drop_monitor(state, client.session_id)

    cond do
      Enum.any?(state.reconnecting, fn {_t, {sid, _}} -> sid == client.session_id end) ->
        {:noreply, state}

      not reconnect_enabled?(state) ->
        remove_client(state, client, reason, 4000, "transport closed")

      true ->
        timer =
          Process.send_after(
            self(),
            {:reconnect_expired, client.reconnection_token},
            reconnect_ttl(state)
          )

        state = %__MODULE__{
          state
          | reconnecting:
              Map.put(state.reconnecting, client.reconnection_token, {client.session_id, timer})
        }

        {:noreply, state}
    end
  end

  defp reconnect_ttl(%__MODULE__{} = state) do
    case Keyword.get(state.options, :reconnect_ttl, @reconnect_ttl) do
      ttl when is_integer(ttl) and ttl > 0 -> ttl
      _ -> @reconnect_ttl
    end
  end

  defp reconnect_enabled?(state),
    do: Keyword.get(state.options, :reconnect_ttl, @reconnect_ttl) not in [false, 0]

  # -------------------------------------------------------------------------
  # Presence: трекинг пользователя на время его жизни в комнате.
  # Трекает сам процесс комнаты (смерть комнаты чистит записи сама);
  # ключ {user_id, room_id} — комнаты-держатели независимы, уход из одной
  # не гасит онлайн юзера в другой.
  # -------------------------------------------------------------------------

  defp track_presence(%__MODULE__{} = state, %Client{} = client) do
    case presence_identity(client.auth) do
      {user_id, username} ->
        ExGames.Presence.track_room_user(user_id, state.room_id, %{"username" => username})

      nil ->
        :ok
    end

    :ok
  end

  defp untrack_presence(%__MODULE__{} = state, %Client{} = client) do
    case presence_identity(client.auth) do
      {user_id, _username} ->
        ExGames.Presence.untrack_room_user(user_id, state.room_id)

      nil ->
        :ok
    end
  end

  # user_id + username из auth-данных брони (%{"user_id" => …} веб-слоя);
  # анонимные комнаты (без user_id в auth) не трекаются
  defp presence_identity(auth) when is_map(auth) do
    user_id = auth_value(auth, "user_id") || auth_value(auth, :user_id)

    if user_id in [nil, ""],
      do: nil,
      else: {to_string(user_id), auth_value(auth, "username") || auth_value(auth, :username)}
  end

  defp presence_identity(_auth), do: nil

  defp auth_value(auth, key) do
    case Map.get(auth, key) do
      nil ->
        nil

      value ->
        value
        |> to_string()
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end

  defp clear_reconnect_slot(%__MODULE__{} = state, session_id) do
    Enum.reduce(state.reconnecting, state, fn {token, {sid, timer}}, %__MODULE__{} = acc ->
      if sid == session_id do
        Process.cancel_timer(timer)
        %__MODULE__{acc | reconnecting: Map.delete(acc.reconnecting, token)}
      else
        acc
      end
    end)
  end

  defp drop_monitor(%__MODULE__{} = state, session_id) do
    case Map.pop(state.monitors, session_id) do
      {nil, _} ->
        state

      {ref, monitors} ->
        Process.demonitor(ref, [:flush])
        %__MODULE__{state | monitors: monitors}
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

  # Дельта-режим (:state_sync == :delta): неотправленный дифф уходит текущим
  # клиентам до подключения новичка — новичку затем уходит полный снапшот
  # того же состояния (все клиенты сходятся к одному base).
  defp flush_state_delta(%__MODULE__{} = state) do
    cond do
      state_sync(state) != :delta or is_nil(state.game_state) or is_nil(state.last_sent_state) ->
        state

      true ->
        ops = StateDiff.diff(state.last_sent_state, state.game_state)

        case ops do
          [] ->
            %{state | last_sent_state: state.game_state}

          _ ->
            push_all(state, Wire.encode(:room_state_patch, %{"ops" => ops}))
            %{state | last_sent_state: state.game_state}
        end
    end
  end

  defp broadcast_state_if_dirty(%__MODULE__{state_dirty: true, game_state: game_state} = state)
       when not is_nil(game_state) do
    case push_state_update(state) do
      :skipped -> :noop
      frame -> push_all(state, frame)
    end

    %__MODULE__{state | state_dirty: false, last_sent_state: game_state}
  end

  defp broadcast_state_if_dirty(state), do: state

  # Возвращает кадр для отправки или :skipped (дельта без изменений).
  defp push_state_update(%__MODULE__{game_state: game_state} = state) do
    cond do
      state_sync(state) == :delta and state.last_sent_state != nil and is_map(game_state) ->
        case StateDiff.diff(state.last_sent_state, game_state) do
          [] -> :skipped
          ops -> Wire.encode(:room_state_patch, %{"ops" => ops})
        end

      true ->
        # snapshot-режим либо первая доставка состояния
        Wire.encode(:room_state, game_state)
    end
  end

  defp push_all(%__MODULE__{} = state, frame) do
    state.clients
    |> Map.values()
    |> Enum.each(&push(&1.pid, frame))

    :ok
  end

  defp state_sync(state), do: Keyword.get(state.options, :state_sync, :snapshot)

  # -------------------------------------------------------------------------
  # Room clock: расписание таймеров
  # -------------------------------------------------------------------------

  defp put_timer(%__MODULE__{} = state, key, timer),
    do: %__MODULE__{state | timers: Map.put(state.timers, key, timer)}

  # Перезапись ключа отменяет прежний таймер (key уникален на комнату).
  defp cancel_timer(%__MODULE__{} = state, key) do
    case Map.pop(state.timers, key) do
      {nil, _timers} ->
        state

      {timer, timers} ->
        Process.cancel_timer(timer)
        %__MODULE__{state | timers: timers}
    end
  end

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

    Phoenix.PubSub.broadcast(
      ExGames.PubSub,
      ExGames.Matchmaker.lobby_topic(),
      {:ex_games, :lobby, {:update, listing}}
    )

    :ok
  end

  # Убирает листинг комнаты из ETS и уведомляет лобби.
  defp unpublish_listing(%__MODULE__{room_name: nil}), do: :ok

  defp unpublish_listing(%__MODULE__{} = state) do
    :ets.delete(:ex_games_matchmaker_rooms, state.room_id)

    Phoenix.PubSub.broadcast(
      ExGames.PubSub,
      ExGames.Matchmaker.lobby_topic(),
      {:ex_games, :lobby, {:remove, state.room_id}}
    )

    :ok
  end

  defp close_all(%__MODULE__{} = state, code, message) do
    Enum.each(state.reconnecting, fn {_token, {_sid, timer}} -> Process.cancel_timer(timer) end)

    state.clients
    |> Map.values()
    |> Enum.each(fn client ->
      push_close(client.pid, code, message)

      case Map.get(state.monitors, client.session_id) do
        nil -> :ok
        ref -> Process.demonitor(ref, [:flush])
      end
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

  defp log_callback_error(module, name, exception, stacktrace, room_id) do
    Logger.error(
      "[ex_games] #{module}.#{name}/… raised in room #{room_id}: " <>
        Exception.format(:error, exception, stacktrace)
    )
  end

  # -------------------------------------------------------------------------
  # Встраиваемые модули логики (ExGames.Room.Logic)
  # -------------------------------------------------------------------------

  # Старт цепочки встроенных модулей логики (в порядке объявления).
  defp init_logics([], _create_options, _handle, acc), do: {:ok, Enum.reverse(acc)}

  defp init_logics([mod | rest], create_options, handle, acc) do
    # модули логики ленивы: гарантируем загрузку до первой проверки
    with {:module, ^mod} <- Code.ensure_loaded(mod),
         {:ok, {:ok, logic_state}} <- safe_apply(mod, :logic_init, [create_options, handle]) do
      init_logics(rest, create_options, handle, [{mod, logic_state} | acc])
    else
      {:ok, {:stop, reason}} ->
        {:stop, {:logic_init_failed, mod, reason}}

      {:raise, exception, _} ->
        {:stop, {:logic_init_crashed, mod, exception}}

      :callback_missing ->
        {:stop, {:logic_init_missing, mod}}

      {:error, reason} ->
        {:stop, {:logic_not_loadable, mod, reason}}
    end
  end

  # Цепочка авторизации: комната (handle_auth), затем модули логики
  # (logic_auth) — могут преобразовывать auth-данные и отклонять бронь.
  defp auth_chain(%__MODULE__{} = state, auth_data, options) do
    with {:ok, auth} <-
           apply_auth(state.module, :handle_auth, [auth_data, options, state.handle], auth_data) do
      Enum.reduce_while(state.logics, {:ok, auth}, fn {mod, _ls}, {:ok, acc} ->
        case safe_apply(mod, :logic_auth, [acc, options, state.handle]) do
          {:ok, :ok} ->
            {:cont, {:ok, acc}}

          {:ok, {:ok, auth}} ->
            {:cont, {:ok, auth}}

          {:ok, {:error, reason}} ->
            {:halt, {:error, reason}}

          {:raise, exception, stacktrace} ->
            log_callback_error(state.module, :logic_auth, exception, stacktrace, state.room_id)
            {:halt, {:error, exception}}

          :callback_missing ->
            {:cont, {:ok, acc}}
        end
      end)
    end
  end

  defp apply_auth(mod, fun, args, default_auth) do
    case safe_apply(mod, fun, args) do
      {:ok, :ok} ->
        {:ok, default_auth}

      {:ok, {:ok, auth}} ->
        {:ok, auth}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:raise, exception, stacktrace} ->
        log_callback_error(mod, fun, exception, stacktrace, "n/a")
        {:error, exception}

      :callback_missing ->
        {:ok, default_auth}
    end
  end

  defp put_logic(%__MODULE__{} = state, mod, logic_state) do
    %{state | logics: List.keyreplace(state.logics, mod, 0, {mod, logic_state})}
  end

  # Роутинг кадра: первый модуль с объявленным типом, затем первый
  # wildcard-модуль (клейза `message :_`), затем сама комната.
  defp logic_for_message(%__MODULE__{} = state, type) do
    Enum.find(state.logics, fn {mod, _} ->
      function_exported?(mod, :__message_types__, 0) and type in mod.__message_types__()
    end) ||
      Enum.find(state.logics, fn {mod, _} ->
        function_exported?(mod, :__message_wildcard__, 0) and mod.__message_wildcard__() == true
      end)
  end

  defp logic_for_request(%__MODULE__{} = state, type) do
    Enum.find(state.logics, fn {mod, _} ->
      function_exported?(mod, :__request_types__, 0) and type in mod.__request_types__()
    end) ||
      Enum.find(state.logics, fn {mod, _} ->
        function_exported?(mod, :__request_wildcard__, 0) and mod.__request_wildcard__() == true
      end)
  end

  defp run_logic_join(%__MODULE__{} = state, client, auth) do
    Enum.reduce_while(state.logics, {:ok, state}, fn {mod, logic_state}, {:ok, acc} ->
      case safe_apply(mod, :logic_join, [state.handle, client, auth, logic_state]) do
        {:ok, {:ok, new_state}} ->
          {:cont, {:ok, put_logic(acc, mod, new_state)}}

        {:ok, {:stop, reason, new_state}} ->
          {:halt, {:stop, reason, put_logic(acc, mod, new_state)}}

        {:raise, exception, stacktrace} ->
          log_callback_error(mod, :logic_join, exception, stacktrace, state.room_id)
          {:halt, {:stop, exception, acc}}

        :callback_missing ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp run_logic_leave(%__MODULE__{} = state, client, reason) do
    Enum.reduce(state.logics, state, fn {mod, logic_state}, acc ->
      case safe_apply(mod, :logic_leave, [state.handle, client, reason, logic_state]) do
        {:ok, {:ok, new_state}} -> put_logic(acc, mod, new_state)
        _ -> acc
      end
    end)
  end

  defp put_user_state(%__MODULE__{} = state, user_state) do
    %__MODULE__{state | user_state: user_state}
  end

  # Цепочка logic_info: любые не-служебные сообщения ящика комнаты
  # (PubSub-подписки, пуш от внешних процессов и т.п.).
  defp run_logic_info(%__MODULE__{} = state, msg) do
    Enum.reduce_while(state.logics, {:noreply, state}, fn {mod, logic_state}, {:noreply, acc} ->
      case safe_apply(mod, :logic_info, [msg, logic_state]) do
        {:ok, {:ok, new_state}} ->
          {:cont, {:noreply, put_logic(acc, mod, new_state)}}

        {:ok, {:stop, reason, new_state}} ->
          {:halt, stop_room(put_logic(acc, mod, new_state), reason)}

        {:raise, exception, stacktrace} ->
          log_callback_error(mod, :logic_info, exception, stacktrace, state.room_id)
          {:cont, {:noreply, acc}}

        :callback_missing ->
          {:cont, {:noreply, acc}}
      end
    end)
  end

  defp stop_room(%__MODULE__{} = state, reason) do
    close_all(state, 4002, "room stopped")
    {:stop, {:shutdown, reason}, state}
  end

  defp run_logic_tick(%__MODULE__{} = state, elapsed) do
    Enum.reduce_while(state.logics, {:ok, state}, fn {mod, logic_state}, {:ok, acc} ->
      case safe_apply(mod, :logic_tick, [elapsed, logic_state]) do
        {:ok, {:ok, new_state}} ->
          {:cont, {:ok, put_logic(acc, mod, new_state)}}

        {:ok, {:stop, reason, new_state}} ->
          {:halt, {:stop, reason, put_logic(acc, mod, new_state)}}

        {:raise, exception, stacktrace} ->
          log_callback_error(mod, :logic_tick, exception, stacktrace, state.room_id)
          {:halt, {:stop, exception, acc}}

        :callback_missing ->
          {:cont, {:ok, acc}}
      end
    end)
  end
end
