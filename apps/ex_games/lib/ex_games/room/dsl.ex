defmodule ExGames.Room.DSL do
  @moduledoc false
  # Общая машинерия DSL `message`/`request` для `use ExGames.Room`
  # и `use ExGames.Room.Logic`. Клавзы накапливаются в module attributes
  # (только через @-синтаксис — значения, записанные в макросе через
  # Module.put_attribute, не доживают до __before_compile__ на Elixir 1.19),
  # затем разворачиваются в def-клавзы handle_message/handle_request.

  @doc false
  def register_attributes(module) do
    Module.register_attribute(module, :ex_games_message_clauses, accumulate: true)
    Module.register_attribute(module, :ex_games_request_clauses, accumulate: true)
    :ok
  end

  @doc "Клавзы handle_message (в порядке объявления)."
  def message_clauses(env) do
    Module.get_attribute(env.module, :ex_games_message_clauses)
    |> Enum.reverse()
  end

  @doc "Клавзы handle_request (в порядке объявления)."
  def request_clauses(env) do
    Module.get_attribute(env.module, :ex_games_request_clauses)
    |> Enum.reverse()
  end

  @doc "Объявленные типы сообщений (для диспетчеризации в логики); :_ — wildcard, не тип."
  def message_types(env) do
    message_clauses(env) |> Enum.map(& &1.type) |> Enum.reject(&(&1 == :_)) |> Enum.uniq()
  end

  @doc "Объявленные типы запросов (:_ — wildcard, не тип)."
  def request_types(env) do
    request_clauses(env) |> Enum.map(& &1.type) |> Enum.reject(&(&1 == :_)) |> Enum.uniq()
  end

  @doc "quote-список def-клавз handle_message по накопленным клавзам."
  def generate_message_defs(env) do
    for %{type: type, pattern: pattern, body: body, room: r, client: c, state: s} <-
          message_clauses(env) do
      # wildcard :_ матчит любой тип: фактический тип доступен в клейзе
      # переменной `type` (или `_type`, если тело её не использует)
      type_pattern =
        if type == :_ do
          if body_uses_var?(body, :type), do: Macro.var(:type, nil), else: Macro.var(:_type, nil)
        else
          type
        end

      quote do
        def handle_message(
              unquote(Macro.var(r, nil)),
              unquote(Macro.var(c, nil)),
              unquote(type_pattern),
              unquote(pattern),
              unquote(Macro.var(s, nil))
            ) do
          unquote(body)
        end
      end
    end
  end

  # Переменная {name, meta, context} в теле клейзы (до гигиены) — факт
  # использования. Контекст: nil в теле модуля, Elixir — внутри quote.
  defp body_uses_var?(ast, name) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {^name, _meta, ctx} = node, _acc when is_atom(ctx) or is_nil(ctx) ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
  end

  @doc "Catch-all handle_message: неизвестные сообщения игнорируются."
  def generate_message_catch_all do
    [
      quote do
        def handle_message(_room, _client, _type, _payload, state), do: {:ok, state}
      end
    ]
  end

  @doc "quote-список def-клавз handle_request по накопленным клавзам."
  def generate_request_defs(env) do
    for %{type: type, pattern: pattern, body: body, room: r, client: c, state: s} <-
          request_clauses(env) do
      # wildcard :_ матчит любой тип: фактический тип доступен в клейзе
      # переменной `type` (или `_type`, если тело её не использует)
      type_pattern =
        if type == :_ do
          if body_uses_var?(body, :type), do: Macro.var(:type, nil), else: Macro.var(:_type, nil)
        else
          type
        end

      quote do
        def handle_request(
              unquote(Macro.var(r, nil)),
              unquote(Macro.var(c, nil)),
              request_id,
              unquote(type_pattern),
              unquote(pattern),
              unquote(Macro.var(s, nil))
            ) do
          unquote(body)
        end
      end
    end
  end

  @doc "Catch-all handle_request: неизвестный запрос — ошибка клиенту."
  def generate_request_catch_all do
    [
      quote do
        def handle_request(_room, _client, request_id, _type, _payload, state) do
          {:error, "unknown request", state}
        end
      end
    ]
  end

  @doc "quote-список функций интроспекции объявленных типов."
  def generate_type_introspection(env) do
    message_types = message_types(env)
    request_types = request_types(env)
    wildcard? = :_ in Enum.map(message_clauses(env), & &1.type)
    request_wildcard? = :_ in Enum.map(request_clauses(env), & &1.type)

    [
      # модуль мог определить интроспекцию сам (напр. мост Lua с типами
      # из M.schema) — не дублируем
      unless Module.defines?(env.module, {:__message_types__, 0}) do
        quote do
          @doc false
          def __message_types__, do: unquote(Macro.escape(message_types))
        end
      end,
      unless Module.defines?(env.module, {:__request_types__, 0}) do
        quote do
          @doc false
          def __request_types__, do: unquote(Macro.escape(request_types))
        end
      end,
      unless Module.defines?(env.module, {:__message_wildcard__, 0}) do
        quote do
          @doc false
          def __message_wildcard__, do: unquote(wildcard?)
        end
      end,
      unless Module.defines?(env.module, {:__request_wildcard__, 0}) do
        quote do
          @doc false
          def __request_wildcard__, do: unquote(request_wildcard?)
        end
      end
    ]
    |> Enum.reject(&is_nil/1)
  end
end
