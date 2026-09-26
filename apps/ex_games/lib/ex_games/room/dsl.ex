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

  @doc "Объявленные типы сообщений (для диспетчеризации в логики)."
  def message_types(env) do
    message_clauses(env) |> Enum.map(& &1.type) |> Enum.uniq()
  end

  @doc "Объявленные типы запросов."
  def request_types(env) do
    request_clauses(env) |> Enum.map(& &1.type) |> Enum.uniq()
  end

  @doc "quote-список def-клавз handle_message по накопленным клавзам."
  def generate_message_defs(env) do
    for %{type: type, pattern: pattern, body: body, room: r, client: c, state: s} <-
          message_clauses(env) do
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
    end
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

    [
      quote do
        @doc false
        def __message_types__, do: unquote(Macro.escape(message_types))
      end,
      quote do
        @doc false
        def __request_types__, do: unquote(Macro.escape(request_types))
      end
    ]
  end
end
