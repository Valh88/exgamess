#!/usr/bin/env escript
# Нативный echo-сервер игровой логики (справочная реализация протокола
# ExGames.GameLogic: msgpack + u32 length-prefix по stdin/stdout).
# Msgpack-кодек ниже — минимальный (map/list/bin/int/nil); продакшн-реализации
# на Haxe/Rust/Go используют стандартные msgpack-библиотеки.

defmodule NativeEcho do
  def main(_args) do
    :io.setopts(:standard_io, binary: true)
    loop(<<>>)
  end

  def loop(buffer) do
    case frame(buffer) do
      {doc, rest} ->
        IO.binwrite(:standard_io, encode(reply(doc)))
        loop(rest)

      :incomplete ->
        case IO.binread(:stdio, 1) do
          :eof -> :ok
          {:error, _} -> :ok
          data -> loop(<<buffer::binary, data::binary>>)
        end
    end
  end

  def frame(<<len::size(32), payload::binary-size(len), rest::binary>>) do
    {unpack(payload), rest}
  end

  def frame(_), do: :incomplete

  def encode(term) do
    payload = IO.iodata_to_binary(pack(term))
    <<byte_size(payload)::size(32), payload::binary>>
  end

  # --- протокол логики -------------------------------------------------------

  def reply(%{"op" => "init"}) do
    %{"ok" => true, "state" => %{"tick" => 0, "score" => 0}}
  end

  def reply(%{"op" => "call", "fn" => "add_score", "state" => state, "args" => [amount]}) do
    score = Map.get(state, "score", 0)
    new = score + amount
    %{"ok" => true, "result" => new, "state" => Map.put(state, "score", new)}
  end

  def reply(%{"op" => "tick", "dt" => dt, "state" => state}) do
    tick = Map.get(state, "tick", 0)
    %{"ok" => true, "state" => Map.put(state, "tick", tick + dt)}
  end

  def reply(_), do: %{"ok" => false, "error" => "unknown_op"}

  # --- минимальный msgpack ----------------------------------------------------

  def pack(map) when is_map(map) do
    entries = :maps.to_list(map)
    n = length(entries)

    head =
      if n < 16 do
        <<0x80 + n>>
      else
        <<0xDE, n::16>>
      end

    IO.iodata_to_binary([head, Enum.map(entries, fn {k, v} -> [pack(k), pack(v)] end)])
  end

  def pack(bin) when is_binary(bin) do
    n = byte_size(bin)

    cond do
      n < 32 -> <<0xA0 + n, bin::binary>>
      n < 256 -> <<0xD9, n, bin::binary>>
      true -> <<0xDA, n::16, bin::binary>>
    end
  end

  def pack(i) when is_integer(i) and i >= 0 and i < 128, do: <<i>>

  def pack(list) when is_list(list) do
    n = length(list)
    head = if n < 16, do: <<0x90 + n>>, else: <<0xDC, n::16>>
    IO.iodata_to_binary([head, Enum.map(list, &pack/1)])
  end

  def unpack(bin), do: elem(value(bin), 0)

  defp value(<<0xC0, rest::binary>>), do: {nil, rest}
  defp value(<<b, rest::binary>>) when b >= 0x80 and b < 0x90, do: map(b - 0x80, rest, %{})
  defp value(<<b, rest::binary>>) when b >= 0x90 and b < 0xA0, do: list(b - 0x90, rest, [])
  defp value(<<b, rest::binary>>) when b >= 0xA0 and b < 0xC0, do: str(b - 0xA0, rest)
  defp value(<<0xD9, n, rest::binary>>), do: str(n, rest)
  defp value(<<0xDA, n::16, rest::binary>>), do: str(n, rest)
  defp value(<<0xCC, v, rest::binary>>), do: {v, rest}
  defp value(<<0xCD, v::16, rest::binary>>), do: {v, rest}
  defp value(<<i, rest::binary>>) when i < 0x80, do: {i, rest}

  defp str(n, rest) do
    <<bin::binary-size(n), rest::binary>> = rest
    {bin, rest}
  end

  defp map(0, rest, acc), do: {acc, rest}

  defp map(n, rest, acc) do
    {k, rest} = value(rest)
    {v, rest} = value(rest)
    map(n - 1, rest, Map.put(acc, k, v))
  end

  defp list(0, rest, acc), do: {:lists.reverse(acc), rest}

  defp list(n, rest, acc) do
    {v, rest} = value(rest)
    list(n - 1, rest, [v | acc])
  end
end
