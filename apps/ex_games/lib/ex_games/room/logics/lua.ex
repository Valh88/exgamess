defmodule ExGames.Room.Logics.Lua do
  @moduledoc """
  Мост «комната → Lua-скрипт»: wildcard-модуль `Room.Logic`, транслирующий
  события комнаты в вызовы скрипта через `GameLogic.Server` +
  `GameLogic.Adapters.Lua`, и применяющий вернувшиеся эффекты whitelist'ом.

  ## Прямое использование (один скрипт на комнату — модель по умолчанию)

      use ExGames.Room, logic: [ExGames.Room.Logics.Lua],
        lua_script: "priv/lua/arena.lua",
        lua_args: [],            # опционально
        lua_haxe: true           # опционально: script — чанк `haxe -lua` (шимы рантайма Haxe)
        # max_instructions/max_call_depth — опционально, в опциях скрипта

  Скрипт ищется в опциях комнаты: compile-time `lua_script` или
  create-опция `"lua_script"` (create-опции имеют приоритет).

  ## Несколько Lua-модулей (тонкие модули с выпеченной конфигурацией)

      defmodule MyGame.PhysicsLua do
        use ExGames.Room.Logics.Lua, script: "priv/lua/physics.lua"
      end

      use ExGames.Room, logic: [MyGame.PhysicsLua, MyGame.EconomyLua]

  Опции тонкого модуля: `script:` (обязателен), `haxe: true` (чанк Haxe),
  `args:`, `max_instructions:`, `max_call_depth:`, `wildcard: true`
  (ловить все типы, игнорируя M.schema).

  Диспетчеризация — по типам из `M.schema.messages` скрипта (headless-прогон
  при первом обращении, кэш в `:persistent_term`); скрипт без схемы (или
  `wildcard: true`) ловит все типы — поведение v1. Каждому модулю — своя VM
  и свой срез состояния; id логики — `{room_id, module}`.

  ## Контракт скрипта (в глазах моста)

      M.init(args) -> state
      M.call(fn, args, state) -> {effects, new_state} | new_state
      M.tick(dt, state) -> {effects, new_state} | new_state

  Первое значение пары — **список эффектов** (whitelist; неизвестные
  игнорируются с телеметрией):

      { "broadcast", type, payload }
      { "send_to", session_id, type, payload }
      { "kick", session_id }
      { "lock" }  { "unlock" }
      { "set_metadata", map }

  Особый поток `fn == "request"`: скрипту приходит request-вызов
  (`[type, sid, payload]`), а первое значение пары — **значение-ответ**
  (не эффекты), оно уходит запросившему клиенту кадром RoomResponse;
  null = «обработчика нет» — клиент получает ошибку. Haxe-скрипты
  (`ServerLogic.reply`, наследники `Sync` с @:rpc) получают эту
  развёртку автоматически.

  Новый state публикуется через `set_state/2` (delta-синк работает как есть)
  только при изменении. Ошибка скрипта → телеметрия + игнор (комнату не
  роняем). Мост дополнительно отвечает на request `"schema"` документом
  `M.schema`.
  """

  use ExGames.Room.Logic

  alias ExGames.GameLogic.Adapters.Lua, as: LuaAdapter
  alias ExGames.GameLogic.Adapters.Lua.Shims
  alias ExGames.GameLogic.Server, as: LogicServer
  alias ExGames.Room

  require Logger

  # Согласовано в плане: эффекты из Lua — только через whitelist моста.
  # Нужен новый побочный эффект — добавьте клейзу здесь (явно, с телеметрией),
  # а не доступ скрипта к Elixir.
  @impl true
  def logic_init(options, room) do
    config = config_from_options(options)

    if is_nil(Keyword.get(config, :script)) do
      {:stop, :lua_script_missing}
    else
      base_logic_init(config, room, nil)
    end
  end

  message :_, payload, room, client, state do
    base_logic_message(room, client, type, payload, state)
  end

  @doc false
  def base_logic_message(room, client, type, payload, state) do
    case run(state, room, "message", [type, client.session_id, payload]) do
      {:ok, slice} -> {:ok, slice}
      :error -> {:ok, state}
    end
  end

  # Request-поток: первое значение пары — значение-ответ (НЕ эффекты),
  # состояние публикуется как обычно. nil/ошибка скрипта — ошибка-реплай
  # (клиент мгновенно отклоняет ожидающий запрос).
  @doc false
  def base_logic_request(room, client, type, payload, state) do
    case LogicServer.call(state.id, "request", [type, client.session_id, payload]) do
      # reply вернул null — у скрипта нет обработчика
      {:ok, nil} ->
        {:error, "unknown request", state}

      {:ok, result} ->
        case LogicServer.state(state.id) do
          {:ok, new_state} ->
            {:ok, slice} = publish_and_apply(state, room, nil, new_state)
            {:reply, result, slice}

          {:error, reason} ->
            log_lua_error(state, "request", reason)
            {:error, "request failed", state}
        end

      {:error, reason} ->
        log_lua_error(state, "request", reason)
        {:error, "request failed", state}
    end
  end

  @impl true
  def logic_join(room, client, auth, state) do
    case run(state, room, "join", [client.session_id, auth]) do
      {:ok, slice} -> {:ok, slice}
      :error -> {:ok, state}
    end
  end

  @impl true
  def logic_leave(room, client, reason, state) do
    case run(state, room, "leave", [client.session_id, to_string(reason)]) do
      {:ok, slice} -> {:ok, slice}
      :error -> {:ok, state}
    end
  end

  # Тик моста: драйвит VM вручную (LogicServer.tick/1), авто-тик Server'а
  # выключен (tick_rate: 0) — иначе dt делится между двумя драйверами.
  @impl true
  def logic_tick(_elapsed_ms, state) do
    handle = %Room.Handle{room_id: state.room_id}

    case LogicServer.tick(state.id) do
      {:ok, effects, new_state} ->
        publish_and_apply(state, handle, effects, new_state)

      {:error, reason} ->
        log_lua_error(state, "tick", reason)
        {:ok, state}
    end
  end

  @impl true
  def logic_terminate(_reason, state) do
    LogicServer.stop(state.id)
    :ok
  end

  # Рантайм-ответ на request "schema" — документ M.schema скрипта.
  request "schema", _payload, _room, _client, state do
    case schema_of_state(state) do
      {:ok, schema} -> {:reply, schema, state}
      :error -> {:error, "schema unavailable", state}
    end
  end

  # Остальные request'ы — в скрипт: M.call("request", [type, sid, payload])
  # возвращает {значение-ответ, state}; null = «обработчика нет».
  request :_, payload, room, client, state do
    base_logic_request(room, client, type, payload, state)
  end

  # -------------------------------------------------------------------------
  # Базовые реализации для тонких модулей (use ExGames.Room.Logics.Lua)
  # -------------------------------------------------------------------------

  @doc false
  defmacro __using__(opts) do
    # переменные клейзы сплайсим с контекстом nil: они уходят в head def'а,
    # который DSL генерирует через Macro.var(name, nil)
    room = Macro.var(:room, nil)
    client = Macro.var(:client, nil)
    state = Macro.var(:state, nil)
    payload = Macro.var(:payload, nil)
    type = Macro.var(:type, nil)

    quote do
      use ExGames.Room.Logic

      @ex_games_lua_config unquote(opts)

      # типы из M.schema скрипта (headless-прогон VM при первом обращении);
      # интроспекция определена явно — DSL её не генерирует
      @doc false
      def __message_types__ do
        ExGames.Room.Logics.Lua.schema_types(Keyword.fetch!(@ex_games_lua_config, :script))
      end

      @doc false
      def __message_wildcard__ do
        case Keyword.fetch(@ex_games_lua_config, :wildcard) do
          {:ok, flag} ->
            flag

          :error ->
            ExGames.Room.Logics.Lua.schema_wildcard?(
              Keyword.fetch!(@ex_games_lua_config, :script)
            )
        end
      end

      @impl true
      def logic_init(_options, room) do
        ExGames.Room.Logics.Lua.base_logic_init(@ex_games_lua_config, room, __MODULE__)
      end

      message(:_, unquote(payload), unquote(room), unquote(client), unquote(state)) do
        ExGames.Room.Logics.Lua.base_logic_message(
          unquote(room),
          unquote(client),
          unquote(type),
          unquote(payload),
          unquote(state)
        )
      end

      request(:_, unquote(payload), unquote(room), unquote(client), unquote(state)) do
        ExGames.Room.Logics.Lua.base_logic_request(
          unquote(room),
          unquote(client),
          unquote(type),
          unquote(payload),
          unquote(state)
        )
      end

      @impl true
      def logic_join(room, client, auth, state) do
        ExGames.Room.Logics.Lua.base_logic_join(room, client, auth, state)
      end

      @impl true
      def logic_leave(room, client, reason, state) do
        ExGames.Room.Logics.Lua.base_logic_leave(room, client, reason, state)
      end

      @impl true
      def logic_tick(elapsed_ms, state) do
        ExGames.Room.Logics.Lua.base_logic_tick(elapsed_ms, state)
      end

      @impl true
      def logic_terminate(reason, state) do
        ExGames.Room.Logics.Lua.base_logic_terminate(reason, state)
      end
    end
  end

  # module: nil → id = room_id (прямой режим, один скрипт на комнату);
  # module — тонкий модуль → id = {room_id, module} (несколько VM в комнате).
  def base_logic_init(config, room, module) do
    script = Keyword.fetch!(config, :script)
    id = if module, do: {room.room_id, module}, else: room.room_id

    child_opts =
      [id: id, adapter: LuaAdapter, script: script] ++
        Keyword.take(config, [:args, :max_instructions, :max_call_depth, :haxe, :state_key])

    case DynamicSupervisor.start_child(ExGames.LogicSupervisor, {LogicServer, child_opts}) do
      {:ok, _pid} ->
        {:ok,
         %{
           id: id,
           room_id: room.room_id,
           script: script,
           state_key: Keyword.get(config, :state_key),
           last_state: nil
         }}

      {:error, {:already_started, _}} ->
        {:stop, {:lua_logic_already_started, id}}

      {:error, reason} ->
        {:stop, {:lua_logic_start_failed, id, reason}}
    end
  end

  def base_logic_join(room, client, auth, state) do
    case run(state, room, "join", [client.session_id, auth]) do
      {:ok, slice} -> {:ok, slice}
      :error -> {:ok, state}
    end
  end

  def base_logic_leave(room, client, reason, state) do
    case run(state, room, "leave", [client.session_id, to_string(reason)]) do
      {:ok, slice} -> {:ok, slice}
      :error -> {:ok, state}
    end
  end

  def base_logic_tick(_elapsed_ms, state) do
    handle = %Room.Handle{room_id: state.room_id}

    case LogicServer.tick(state.id) do
      {:ok, effects, new_state} ->
        publish_and_apply(state, handle, effects, new_state)

      {:error, reason} ->
        log_lua_error(state, "tick", reason)
        {:ok, state}
    end
  end

  def base_logic_terminate(_reason, state) do
    LogicServer.stop(state.id)
    :ok
  end

  # -------------------------------------------------------------------------
  # Диспетчеризация по M.schema (для тонких модулей)
  # -------------------------------------------------------------------------

  @doc "Типы сообщений скрипта из `M.schema.messages` ([] — нет схемы/ошибки)."
  @spec schema_types(String.t()) :: [String.t()]
  def schema_types(script) do
    case schema_cached(script) do
      {:ok, %{"messages" => messages}} when is_list(messages) ->
        Enum.filter(messages, &is_binary/1)

      _ ->
        []
    end
  end

  @doc "true — скрипт без объявленных типов (или без схемы): ловит всё."
  @spec schema_wildcard?(String.t()) :: boolean()
  def schema_wildcard?(script), do: schema_types(script) == []

  @doc """
  Headless-прогон скрипта в одноразовой VM: читает `M.schema` (таблица или
  результат вызова `M.schema()`). `{:ok, doc}` | `:error`. Шимы Haxe
  ставятся всегда — чанки Haxe обязаны интроспектироваться независимо от
  флага адаптера; для чистых Lua безвредны.
  """
  @spec extract_schema(String.t()) :: {:ok, map()} | :error
  def extract_schema(script) do
    lua = Shims.install(Lua.new())
    lua = Lua.load_file!(lua, script)

    case Lua.get!(lua, ["M", "schema"]) do
      # get! декодирует таблицы в пары-списки; функции проходят как closure
      nil -> :error
      {:lua_closure, _, _} -> schema_from_call(lua)
      value -> normalize_schema(value)
    end
  rescue
    _ -> :error
  end

  defp schema_from_call(lua) do
    case Lua.call_function(lua, ["M", "schema"], []) do
      {:ok, [value], lua} -> normalize_schema(Lua.decode!(lua, value))
      _ -> :error
    end
  end

  defp normalize_schema(value) do
    case LuaAdapter.validate_doc(value) do
      {:ok, %{} = doc} -> {:ok, doc}
      _ -> :error
    end
  end

  defp schema_cached(script) do
    key = {__MODULE__, script}

    case :persistent_term.get(key, :missing) do
      :missing ->
        schema = extract_schema(script)
        :persistent_term.put(key, schema)
        schema

      cached ->
        cached
    end
  end

  defp schema_of_state(%{script: script}) when is_binary(script), do: schema_cached(script)
  defp schema_of_state(_), do: :error

  # -------------------------------------------------------------------------
  # Внутреннее
  # -------------------------------------------------------------------------

  defp config_from_options(options) do
    script =
      Map.get(options, :lua_script) || Map.get(options, "lua_script") ||
        Map.get(options, :script) || Map.get(options, "script")

    args =
      Map.get(options, :lua_args) || Map.get(options, "lua_args") ||
        Map.get(options, :args) || []

    haxe? =
      [
        Map.get(options, :lua_haxe),
        Map.get(options, "lua_haxe"),
        Map.get(options, :haxe),
        Map.get(options, "haxe")
      ]
      |> Enum.any?(&(&1 == true))

    state_key =
      Map.get(options, :lua_state_key) || Map.get(options, "lua_state_key") ||
        Map.get(options, :state_key) || Map.get(options, "state_key")

    [script: script, args: List.wrap(args), haxe: haxe?]
    |> put_option(options, :state_key, state_key)
    |> put_limit(options, :max_instructions)
    |> put_limit(options, :max_call_depth)
  end

  defp put_option(config, _options, _key, nil), do: config
  defp put_option(config, _options, key, value), do: Keyword.put(config, key, value)

  defp put_limit(config, options, key) do
    case Map.get(options, key) || Map.get(options, Atom.to_string(key)) do
      nil -> config
      value -> Keyword.put(config, key, value)
    end
  end

  # Вызов скрипта + публикация нового state + применение эффектов.
  # Возвращает обновлённый срез; ошибка скрипта — телеметрия и :error
  # (комнату не роняем, состояние остаётся прежним).
  defp run(state, handle, fn_name, args) do
    case LogicServer.call(state.id, fn_name, args) do
      {:ok, effects} ->
        case LogicServer.state(state.id) do
          {:ok, new_state} ->
            publish_and_apply(state, handle, effects, new_state)

          {:error, reason} ->
            log_lua_error(state, fn_name, reason)
            :error
        end

      {:error, reason} ->
        log_lua_error(state, fn_name, reason)
        :error
    end
  end

  # state_key: документ модуля публикуется в СВОЮ корневую ветку общего
  # состояния (Room.set_state_branch/3) — модули не затирают друг друга.
  # Без state_key документ заменяет корень (прямой режим).
  defp publish_and_apply(state, handle, effects, new_state) do
    unless new_state == state.last_state do
      case Map.get(state, :state_key) do
        nil -> set_state(handle, new_state)
        key -> ExGames.Room.set_state_branch(handle, key, new_state)
      end
    end

    apply_effects(handle, effects)
    {:ok, %{state | last_state: new_state}}
  end

  defp apply_effects(_handle, nil), do: :ok
  defp apply_effects(_handle, false), do: :ok

  defp apply_effects(handle, effects) when is_list(effects) do
    Enum.each(effects, &apply_effect(handle, &1))
  end

  defp apply_effects(_handle, other) do
    Logger.warning("[ex_games] lua logic: effects must be a list, got: #{inspect(other)}")
  end

  defp apply_effect(handle, ["broadcast", type, payload]) do
    broadcast(handle, type, payload)
  end

  defp apply_effect(handle, ["send_to", session_id, type, payload]) do
    send_to(handle, session_id, type, payload)
  end

  defp apply_effect(handle, ["kick", session_id]) do
    kick(handle, session_id)
  end

  defp apply_effect(handle, ["lock"]), do: lock(handle)
  defp apply_effect(handle, ["unlock"]), do: unlock(handle)

  defp apply_effect(handle, ["set_metadata", metadata]) when is_map(metadata) do
    set_metadata(handle, metadata)
  end

  defp apply_effect(_handle, effect) do
    Logger.warning("[ex_games] lua logic: unknown effect #{inspect(effect)}")

    :telemetry.execute([:ex_games, :room, :logic_lua_unknown_effect], %{count: 1}, %{})
  end

  defp log_lua_error(state, fn_name, reason) do
    Logger.warning(
      "[ex_games] lua logic #{inspect(state.id)} #{fn_name} failed: #{inspect(reason)}"
    )

    :telemetry.execute([:ex_games, :room, :logic_lua_error], %{count: 1}, %{
      room_id: state.room_id,
      fn: fn_name
    })
  end
end
