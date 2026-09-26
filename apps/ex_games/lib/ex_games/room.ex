defmodule ExGames.Room do
  @moduledoc """
  Объявление игровой комнаты: behaviour + DSL.

  Комната — GenServer под `ExGames.RoomSupervisor`, адресуемая через
  `ExGames.RoomRegistry` по `room_id`. Игровой модуль описывает жизненный
  цикл и обработку сообщений:

      defmodule MyGame.Arena do
        use ExGames.Room, max_clients: 8, patch_rate: 50

        @impl true
        def room_init(_options, room) do
          {:ok, %{players: %{}}}
        end

        @impl true
        def handle_join(room, client, auth, state) do
          broadcast(room, "join", %{"session_id" => client.session_id})
          {:ok, Map.put(state, :players, Map.put(state.players, client.session_id, 0))}
        end

        message "move", %{"x" => x, "y" => y}, room, client, state do
          broadcast(room, "move", %{"who" => client.session_id, "x" => x, "y" => y})
          {:ok, state}
        end

        @impl true
        def handle_leave(room, client, reason, state) do
          broadcast(room, "left", %{"session_id" => client.session_id})
          {:ok, Map.update!(state, :players, &Map.delete(&1, client.session_id))}
        end
      end

  ## Опции `use ExGames.Room`

    * `:max_clients` — предел клиентов (по умолчанию `8`; `:infinity` — без предела).
    * `:patch_rate` — частота тика, мс (по умолчанию `50`). Тик вызывает
      `handle_tick/2` (если определён) и рассылает состояние при изменении.
    * `:auto_dispose` — закрывать комнату, когда клиентов нет (по умолчанию `true`).
    * `:rate_limit` — максимум сообщений от клиента в секунду (по умолчанию `120`).

  ## Колбэки

    * `room_init(options, room)` — при создании; возвращает `{:ok, state}`.
    * `handle_auth(auth_data, options, room)` — проверка при брони места
      (вызывается матчмейкером до выделения сессии); возвращает `:ok`,
      `{:ok, auth}` или `{:error, reason}`. По умолчанию `:ok`.
    * `handle_join(room, client, auth, state)`.
    * `handle_leave(room, client, reason, state)`.
    * `handle_tick(elapsed_ms, state)` — опционально.
    * `handle_info(msg, state)` — опционально (по умолчанию игнор).
    * `room_terminate(reason, state)` — опционально.

  ## DSL

    * `message type, pattern, room, client, state do ... end` — клавза
      обработки сообщения `{:room_data, type, payload}`. Тело возвращает
      `{:ok, state}` / `{:stop, reason, state}`.
    * `request type, pattern, room, client, state do ... end` — клавза
      запрос-ответ; тело возвращает `{:reply, payload, state}` или `{:ok, state}`.

  Внутри тела клавз доступны функции-эффекты `ExGames.Room`:
  `broadcast/3`, `send_to/3`, `kick/2`, `lock/1`, `unlock/1`, `set_metadata/2`,
  `set_state/2`, `clients/1`, `count/1`.
  """

  alias ExGames.Room.Client

  @type state :: term()

  @typedoc "Handle комнаты — передаётся колбэкам и эффектам."
  @type handle :: %__MODULE__.Handle{room_id: ExGames.Id.id()}

  @typedoc "Причина выхода клиента: `:leave`, `:kick`, `:closed`, `:crashed`."
  @type leave_reason :: :leave | :kick | :closed | :crashed

  @typedoc "Пользовательские auth-данные (результат handle_auth)."
  @type auth :: term()

  @callback room_init(options :: map(), handle :: handle()) ::
              {:ok, state()} | {:stop, reason :: term()}

  @callback handle_auth(auth_data :: term(), options :: map(), handle :: handle()) ::
              :ok | {:ok, Client.auth()} | {:error, reason :: term()}

  @callback handle_join(handle(), Client.t(), auth :: auth(), state()) ::
              {:ok, state()} | {:stop, reason :: term(), state()}

  @callback handle_leave(handle(), Client.t(), leave_reason(), state()) :: {:ok, state()}

  @callback handle_tick(elapsed_ms :: non_neg_integer(), state()) ::
              {:ok, state()} | {:stop, reason :: term(), state()}

  @callback handle_message(handle(), Client.t(), type :: String.t() | integer(), payload :: term(), state()) ::
              {:ok, state()} | {:stop, reason :: term(), state()}

  @callback handle_request(handle(), Client.t(), request_id :: non_neg_integer(),
              type :: String.t() | integer(), payload :: term(), state()
            ) ::
              {:reply, reply :: term(), state()}
              | {:ok, state()}
              | {:error, reason :: term(), state()}

  @callback handle_info(msg :: term(), state()) :: {:ok, state()}

  @callback room_terminate(reason :: term(), state()) :: term()

  @optional_callbacks handle_auth: 3,
                      handle_join: 4,
                      handle_leave: 4,
                      handle_tick: 2,
                      handle_message: 5,
                      handle_request: 6,
                      handle_info: 2,
                      room_terminate: 2

  @default_options [
    max_clients: 8,
    patch_rate: 50,
    auto_dispose: true,
    rate_limit: 120
  ]

  @doc false
  def default_options, do: @default_options

  # ---------------------------------------------------------------------------
  # Макросы
  # ---------------------------------------------------------------------------

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour ExGames.Room

      import ExGames.Room,
        only: [message: 6, request: 6, broadcast: 3, send_to: 4, kick: 2, lock: 1,
               unlock: 1, set_metadata: 2, set_state: 2, clients: 1, count: 1]

      Module.register_attribute(__MODULE__, :ex_games_message_clauses, accumulate: true)
      Module.register_attribute(__MODULE__, :ex_games_request_clauses, accumulate: true)

      @ex_games_options Keyword.merge(ExGames.Room.default_options(), opts)

      @doc false
      def __room_options__, do: @ex_games_options

      @before_compile ExGames.Room
    end
  end

  @doc """
  Объявляет обработчик сообщения `{:room_data, type, payload}`:

      message "move", %{"x" => x}, room, client, state do
        ...
        {:ok, state}
      end

  Клавз собираются компилятором; несработавшие сообщения молча игнорируются.
  """
  defmacro message(type, pattern, room, client, state, do: body) do
    pattern = Macro.escape(pattern)
    body = Macro.escape(body)

    quote do
      @ex_games_message_clauses %{
        type: unquote(type),
        pattern: unquote(pattern),
        body: unquote(body),
        room: unquote(var_name!(room)),
        client: unquote(var_name!(client)),
        state: unquote(var_name!(state))
      }
    end
  end

  @doc """
  Объявляет обработчик запроса `{:room_request, request_id, type, payload}`.
  Тело возвращает `{:reply, payload, state}` (клиенту уйдёт `:room_response`)
  или `{:ok, state}` (ответ не отправляется).
  """
  defmacro request(type, pattern, room, client, state, do: body) do
    pattern = Macro.escape(pattern)
    body = Macro.escape(body)

    quote do
      @ex_games_request_clauses %{
        type: unquote(type),
        pattern: unquote(pattern),
        body: unquote(body),
        room: unquote(var_name!(room)),
        client: unquote(var_name!(client)),
        state: unquote(var_name!(state))
      }
    end
  end

  # Имя переменной из AST (для перепривязки в сгенерированной клавзе).
  defp var_name!({name, _meta, nil}) when is_atom(name) and name != :_, do: name

  defp var_name!(other) do
    raise ArgumentError,
          "expected a variable name, got: #{Macro.to_string(other)}"
  end

  defmacro __before_compile__(env) do
    message_clauses =
      Module.get_attribute(env.module, :ex_games_message_clauses)
      |> Enum.reverse()
      |> Enum.map(fn %{type: type, pattern: pattern, body: body, room: r, client: c, state: s} ->
        quote do
          def handle_message(
                unquote(Macro.var(r, nil)),
                unquote(Macro.var(c, nil)),
                unquote(type),
                unquote(pattern),
                unquote(Macro.var(s, nil))
              ) do
            unquote(body)
          end
        end
      end)

    request_clauses =
      Module.get_attribute(env.module, :ex_games_request_clauses)
      |> Enum.reverse()
      |> Enum.map(fn %{type: type, pattern: pattern, body: body, room: r, client: c, state: s} ->
        quote do
          def handle_request(
                unquote(Macro.var(r, nil)),
                unquote(Macro.var(c, nil)),
                request_id,
                unquote(type),
                unquote(pattern),
                unquote(Macro.var(s, nil))
              ) do
            unquote(body)
          end
        end
      end)

    quote do
      unquote_splicing(message_clauses)

      # Неизвестные сообщения игнорируются (с телеметрией на стороне сервера).
      def handle_message(_room, _client, _type, _payload, state), do: {:ok, state}

      unquote_splicing(request_clauses)

      # Неизвестные запросы: ошибка клиенту, состояние без изменений.
      def handle_request(_room, _client, request_id, _type, _payload, state) do
        {:error, "unknown request", state}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Эффекты (вызываются внутри колбэков/клавз; адресат — через Registry)
  # ---------------------------------------------------------------------------

  @spec broadcast(handle(), String.t() | integer(), term()) :: :ok
  def broadcast(%__MODULE__.Handle{} = room, type, payload) do
    GenServer.cast(via(room.room_id), {:broadcast, type, payload})
  end

  @spec send_to(handle(), ExGames.Id.id(), String.t() | integer(), term()) :: :ok
  def send_to(%__MODULE__.Handle{} = room, session_id, type, payload) do
    GenServer.cast(via(room.room_id), {:send_to, session_id, type, payload})
  end

  @doc "Отключает клиента (вызывает `handle_leave` с причиной `:kick` и закрытие транспорта)."
  @spec kick(handle(), ExGames.Id.id()) :: :ok
  def kick(%__MODULE__.Handle{} = room, session_id) do
    GenServer.cast(via(room.room_id), {:kick, session_id})
  end

  @doc "Закрывает комнату для новых подключений (матчмейкер перестаёт её отдавать)."
  @spec lock(handle()) :: :ok
  def lock(%__MODULE__.Handle{} = room), do: GenServer.cast(via(room.room_id), :lock)

  @spec unlock(handle()) :: :ok
  def unlock(%__MODULE__.Handle{} = room), do: GenServer.cast(via(room.room_id), :unlock)

  @doc "Обновляет публичные метаданные комнаты (видны в листинге лобби)."
  @spec set_metadata(handle(), map()) :: :ok
  def set_metadata(%__MODULE__.Handle{} = room, metadata) when is_map(metadata) do
    GenServer.cast(via(room.room_id), {:set_metadata, metadata})
  end

  @doc "Задаёт игровое состояние для рассылки (полный снапшот на тике)."
  @spec set_state(handle(), term()) :: :ok
  def set_state(%__MODULE__.Handle{} = room, game_state) do
    GenServer.cast(via(room.room_id), {:set_state, ExGames.Serialization.to_wire(game_state)})
  end

  @doc "Список подключённых клиентов."
  @spec clients(handle()) :: [ExGames.Id.id()]
  def clients(%__MODULE__.Handle{} = room) do
    GenServer.call(via(room.room_id), :list_clients)
  end

  @doc "Число подключённых клиентов."
  @spec count(handle()) :: non_neg_integer()
  def count(%__MODULE__.Handle{} = room) do
    room |> via() |> GenServer.call(:client_count)
  end

  @doc "Via-имя комнаты для Registry/DynamicSupervisor."
  @spec via(ExGames.Id.id()) :: {:via, module(), {module(), ExGames.Id.id()}}
  def via(room_id), do: {:via, Registry, {ExGames.RoomRegistry, {:room, room_id}}}
end
