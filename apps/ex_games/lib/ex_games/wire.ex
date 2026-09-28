defmodule ExGames.Wire do
  @moduledoc """
  Кодек бинарного протокола: кадр = `[opcode :: unsigned-8][msgpack]`.

  Коды операций совместимы с Colyseus (v0.16+), что оставляет возможность
  Colyseus-совместимого адаптера в будущем:

  | код | имя | направление |
  |----:|-----|-------------|
  | 10 | `:join_room` | сервер → клиент (рукопожатие) |
  | 11 | `:error` | сервер → клиент |
  | 12 | `:leave_room` | оба направления |
  | 13 | `:room_data` | оба направления |
  | 14 | `:room_state` | сервер → клиент (полный снапшот) |
  | 15 | `:room_state_patch` | сервер → клиент (дельта; зарезервировано) |
  | 18 | `:ping` | оба направления (без payload — однобайтовый; с payload — эхо для синхронизации времени) |
  | 21 | `:room_request` | клиент → сервер (запрос с request_id) |
  | 22 | `:room_response` | сервер → клиент (ответ на request_id) |

  Полная спецификация — `doc/PROTOCOL.md` в корне репозитория.
  """

  @typedoc "Код операции кадра."
  @type opcode ::
          :join_room
          | :error
          | :leave_room
          | :room_data
          | :room_state
          | :room_state_patch
          | :ping
          | :room_request
          | :room_response

  @typedoc "Сырой кадр протокола."
  @type frame :: binary()

  @typedoc "Разобранный кадр."
  @type decoded ::
          {:join_room, map()}
          | {:error, map()}
          | {:leave_room}
          | {:room_data, type :: String.t() | integer(), payload :: term()}
          | {:room_state, state :: term()}
          | {:room_state_patch, patch :: term()}
          | {:ping}
          | {:ping, payload :: term()}
          | {:room_request, request_id :: non_neg_integer(), type :: String.t() | integer(),
             payload :: term()}
          | {:room_response, request_id :: non_neg_integer(), payload :: term()}

  @opcodes %{
    join_room: 10,
    error: 11,
    leave_room: 12,
    room_data: 13,
    room_state: 14,
    room_state_patch: 15,
    ping: 18,
    room_request: 21,
    room_response: 22
  }

  @codes Map.new(@opcodes, fn {name, code} -> {code, name} end)

  @doc "Код операции по имени."
  @spec opcode_number(opcode()) :: non_neg_integer()
  for {name, code} <- @opcodes do
    def opcode_number(unquote(name)), do: unquote(code)
  end

  @doc "Имя операции по коду (для диагностики)."
  @spec opcode_name(non_neg_integer()) :: opcode() | :unknown
  def opcode_name(code), do: Map.get(@codes, code, :unknown)

  @doc """
  Кодирует кадр `[opcode][msgpack]`. Для `:ping` без payload кадр однобайтовый;
  с payload — клиентская метка времени для синхронизации часов (сервер эхирует
  её вместе со своим штампом).
  """
  @spec encode(opcode(), term()) :: frame()
  def encode(opcode, payload \\ nil)

  def encode(:ping, nil), do: <<opcode_number(:ping)::8>>

  def encode(:ping, payload), do: frame(:ping, payload)

  def encode(:join_room, options),
    do: frame(:join_room, options)

  def encode(:error, %{code: _} = payload),
    do: frame(:error, payload)

  def encode(:error, message) when is_binary(message),
    do: frame(:error, %{code: 526, message: message})

  def encode(:leave_room, _payload), do: <<opcode_number(:leave_room)::8>>

  def encode(:room_data, {type, payload}),
    do: frame(:room_data, %{t: type, p: payload})

  def encode(:room_state, state),
    do: frame(:room_state, state)

  def encode(:room_state_patch, patch),
    do: frame(:room_state_patch, patch)

  def encode(:room_request, {request_id, type, payload}),
    do: frame(:room_request, %{i: request_id, t: type, p: payload})

  def encode(:room_response, {request_id, payload}),
    do: frame(:room_response, %{i: request_id, p: payload})

  defp frame(opcode, payload) do
    [<<opcode_number(opcode)::8>>, Msgpax.pack!(payload, iodata: true)]
    |> IO.iodata_to_binary()
  end

  @doc """
  Разбирает кадр. Возвращает `{:ok, decoded}` или `{:error, :invalid_frame}`.

  Неизвестный код операции считается ошибкой: клиент и сервер обязаны
  говорить на одном протоколе.
  """
  @spec decode(frame()) :: {:ok, decoded()} | {:error, :invalid_frame}
  def decode(<<18>>), do: {:ok, {:ping}}
  def decode(<<12>>), do: {:ok, {:leave_room}}

  def decode(<<code::8, rest::binary>>) when is_map_key(@codes, code) do
    case Msgpax.unpack(rest) do
      {:ok, payload} -> {:ok, build(Map.get(@codes, code), payload)}
      _ -> {:error, :invalid_frame}
    end
  rescue
    _ -> {:error, :invalid_frame}
  end

  def decode(_frame), do: {:error, :invalid_frame}

  defp build(:join_room, options) when is_map(options), do: {:join_room, options}
  defp build(:ping, payload), do: {:ping, payload}
  defp build(:error, payload) when is_map(payload), do: {:error, payload}
  defp build(:room_data, %{"t" => t, "p" => p}), do: {:room_data, t, p}
  defp build(:room_data, %{t: t, p: p}), do: {:room_data, t, p}
  defp build(:room_state, state), do: {:room_state, state}
  defp build(:room_state_patch, patch), do: {:room_state_patch, patch}

  defp build(:room_request, %{"i" => i, "t" => t, "p" => p}) when is_integer(i),
    do: {:room_request, i, t, p}

  defp build(:room_request, %{i: i, t: t, p: p}) when is_integer(i),
    do: {:room_request, i, t, p}

  defp build(:room_response, %{"i" => i, "p" => p}) when is_integer(i),
    do: {:room_response, i, p}

  defp build(:room_response, %{i: i, p: p}) when is_integer(i),
    do: {:room_response, i, p}

  defp build(_code, _payload), do: raise(ArgumentError, "invalid frame payload")
end
