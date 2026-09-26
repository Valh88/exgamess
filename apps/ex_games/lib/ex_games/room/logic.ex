defmodule ExGames.Room.Logic do
  @moduledoc """
  Контракт встраиваемого модуля игровой логики (по образу Colyseus:
  логика комнаты — подключаемый модуль, оболочка комнаты его делегирует).

  Комната-оболочка объявляет логи декларативно:

      defmodule MyGame.Arena do
        use ExGames.Room, max_clients: 8, patch_rate: 50,
          logic: [MyGame.Rules.Scoring, MyGame.Rules.Movement]

        @impl true
        def room_init(_options, _room), do: {:ok, nil}
      end

  Модуль логики использует `use ExGames.Room.Logic` и описывает поведение
  тем же DSL, что и комната (`message`/`request` + эффекты `broadcast`,
  `send_to`, `set_state`, …):

      defmodule MyGame.Rules.Scoring do
        use ExGames.Room.Logic

        @impl true
        def logic_init(_options, _room), do: {:ok, %{scores: %{}}}

        @impl true
        def logic_join(room, client, _auth, state) do
          broadcast(room, "joined", %{"session_id" => client.session_id})
          {:ok, put_in(state, [:scores, client.session_id], 0)}
        end

        message "hit", %{"target" => t}, room, client, state do
          broadcast(room, "hit", %{"by" => client.session_id, "target" => t})
          {:ok, update_in(state, [:scores, t], &(&1 + 1))}
        end
      end

  ## Семантика композиции

    * **Диспетчеризация сообщений** — по объявленным типам (аналог реестра
      `onMessage` в Colyseus): кадр `ROOM_DATA` уходит в первый встроенный
      модуль, объявивший этот тип (`__message_types__/0` генерируется из
      клавз `message`). Если не объявил никто — обрабатывает сама комната,
      иначе игнорируется. Два модуля с одним типом: побеждает первый в
      списке `:logic`.
    * **События join/leave/tick** — цепочкой через все модули (в порядке
      объявления); каждый хранит **свой срез состояния** внутри комнаты.
      `{:stop, reason, state}` любого модуля останавливает комнату.
    * **Авторизация** — цепочкой на этапе брони места: комната
      (`handle_auth`), затем модули (`logic_auth`); могут преобразовывать
      auth-данные и отклонять бронь.
    * **Изоляция**: краш клавзы модуля не роняет комнату (телеметрия +
      продолжение), `{:stop, …}` — управляемая остановка.

  Модуль логики — обычный Elixir-модуль: юнит-тесты без комнаты, повторное
  использование в разных комнатах, вынос в нативный процесс через
  `ExGames.GameLogic` позже — без изменения комнаты.
  """

  alias ExGames.Room
  alias ExGames.Room.Client

  @typedoc "Срез состояния модуля логики."
  @type state :: term()

  @callback logic_init(options :: map(), room :: Room.handle()) ::
              {:ok, state()} | {:stop, reason :: term()}

  @callback logic_auth(auth_data :: term(), options :: map(), room :: Room.handle()) ::
              :ok | {:ok, auth :: term()} | {:error, reason :: term()}

  @callback logic_join(room :: Room.handle(), client :: Client.t(), auth :: term(), state()) ::
              {:ok, state()} | {:stop, reason :: term(), state()}

  @callback logic_leave(room :: Room.handle(), client :: Client.t(), reason :: Room.leave_reason(), state()) ::
              {:ok, state()}

  @callback logic_tick(elapsed_ms :: non_neg_integer(), state()) ::
              {:ok, state()} | {:stop, reason :: term(), state()}

  @callback logic_terminate(reason :: term(), state()) :: term()

  @optional_callbacks [
    {:logic_auth, 3},
    {:logic_join, 4},
    {:logic_leave, 4},
    {:logic_tick, 2},
    {:logic_terminate, 2}
  ]

  # -------------------------------------------------------------------------

  defmacro __using__(_opts) do
    quote do
      @behaviour ExGames.Room.Logic

      import ExGames.Room,
        only: [message: 6, request: 6, broadcast: 3, send_to: 4, kick: 2, lock: 1,
               unlock: 1, set_metadata: 2, set_state: 2, clients: 1, count: 1]

      ExGames.Room.DSL.register_attributes(__MODULE__)

      @before_compile ExGames.Room.Logic
    end
  end

  defmacro __before_compile__(env) do
    defaults = logic_defaults(env)

    quote do
      unquote_splicing(ExGames.Room.DSL.generate_message_defs(env))
      unquote_splicing(ExGames.Room.DSL.generate_message_catch_all())

      unquote_splicing(ExGames.Room.DSL.generate_request_defs(env))
      unquote_splicing(ExGames.Room.DSL.generate_request_catch_all())

      unquote_splicing(ExGames.Room.DSL.generate_type_introspection(env))
      unquote_splicing(defaults)
    end
  end

  # Дефолтные реализации опциональных колбэков (только для неопределённых).
  defp logic_defaults(env) do
    state = Macro.var(:state, nil)

    defaults = [
      {:logic_auth, 3, [:_auth_data, :_options, :_room], :ok},
      {:logic_join, 4, [:_room, :_client, :_auth, :state], {:ok, state}},
      {:logic_leave, 4, [:_room, :_client, :_reason, :state], {:ok, state}},
      {:logic_tick, 2, [:_elapsed_ms, :state], {:ok, state}},
      {:logic_terminate, 2, [:_reason, :_state], :ok}
    ]

    for {name, arity, var_names, body} <- defaults,
        not Module.defines?(env.module, {name, arity}) do
      vars = for v <- var_names, do: (is_atom(v) && Macro.var(v, nil)) || v

      quote do
        @doc false
        def unquote(name)(unquote_splicing(vars)) do
          unquote(body)
        end
      end
    end
  end
end
