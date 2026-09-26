defmodule ExGames.Id do
  @moduledoc """
  Генерация идентификаторов.

  * `room_id/0` — короткий публичный идентификатор комнаты (9 символов,
    как в Colyseus).
  * `session_id/0` — идентификатор сессии клиента в комнате.
  * `token/0` — reconnection-токен: длиннее и непредсказуемее.

  Идентификаторы безопасны для URL и удобны для клиентов на любом
  нативном языке (только ASCII-буквы и цифры).
  """

  @type id :: String.t()

  @room_alphabet "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
  @token_alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

  @doc "Публичный идентификатор комнаты (9 символов)."
  @spec room_id() :: id()
  def room_id, do: random(@room_alphabet, 9)

  @doc "Идентификатор сессии клиента в комнате."
  @spec session_id() :: id()
  def session_id, do: random(@room_alphabet, 12)

  @doc "Reconnection-токен (одноразовый, с TTL на стороне комнаты)."
  @spec token() :: id()
  def token, do: random(@token_alphabet, 32)

  @doc "Служебный идентификатор процесса логики."
  @spec logic_id() :: id()
  def logic_id, do: random(@room_alphabet, 9)

  defp random(alphabet, length) do
    alphabet
    |> String.graphemes()
    |> pick(length, "")
  end

  defp pick(_alphabet, 0, acc), do: acc

  defp pick(alphabet, remaining, acc) do
    pick(alphabet, remaining - 1, acc <> Enum.at(alphabet, :rand.uniform(length(alphabet)) - 1))
  end
end
