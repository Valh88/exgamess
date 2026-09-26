defprotocol ExGames.Serialization do
  @moduledoc """
  Преобразование игровых структур в wire-формат (значения, пригодные для
  msgpack: map'ы со string/atom-ключами, списки, числа, строки, boolean).

  Используется при сериализации состояния комнаты (`ExGames.Room.put_state/2`)
  и полезной нагрузки сообщений. Для своих структур достаточно деривации:

      defmodule MyGame.Player do
        @derive ExGames.Serialization
        defstruct [:name, :score]
      end

  Имена полей приводятся к строкам — конвенция протокола под Haxe-клиенты
  (только string-ключи в msgpack-map'ах, без ext-типов).
  """

  @fallback_to_any true
  @spec to_wire(t()) :: term()
  def to_wire(value)
end

defimpl ExGames.Serialization, for: Any do
  def to_wire(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.map(fn {key, value} ->
      {Atom.to_string(key), ExGames.Serialization.to_wire(value)}
    end)
    |> Map.new()
  end

  def to_wire(value) when is_map(value) do
    Map.new(value, fn {key, value} ->
      key =
        cond do
          is_atom(key) and not is_nil(key) -> Atom.to_string(key)
          true -> key
        end

      {key, ExGames.Serialization.to_wire(value)}
    end)
  end

  def to_wire(value) when is_list(value) do
    Enum.map(value, &ExGames.Serialization.to_wire/1)
  end

  def to_wire(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&ExGames.Serialization.to_wire/1)
  end

  def to_wire(value), do: value
end
