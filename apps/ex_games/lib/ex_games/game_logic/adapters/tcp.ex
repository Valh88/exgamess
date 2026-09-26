defmodule ExGames.GameLogic.Adapters.TCP do
  @moduledoc """
  Нативная логика по TCP (`gen_tcp`, `{:packet, :raw, 4}` framing — тот же
  u32 length-prefix, что у stdio-варианта).

  Опции: `host`, `port`, `args` (init). Полезен, когда нативная логика —
  отдельный сетевой сервис на другой машине или обслуживает несколько
  комнат.
  """

  use ExGames.GameLogic.Adapters.Native

  alias ExGames.GameLogic.Framing

  def open(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)

    with {:ok, host_charlist} <- to_host(host),
         {:ok, socket} <-
           :gen_tcp.connect(
             host_charlist,
             port,
             [
               :binary,
               {:packet, :raw, 4},
               {:active, false},
               {:nodelay, true}
             ],
             5_000
           ) do
      {:ok, socket}
    end
  end

  def exchange(socket, doc, timeout) do
    with :ok <- :gen_tcp.send(socket, Framing.encode(doc)),
         {:ok, data} <- :gen_tcp.recv(socket, 0, timeout) do
      case Framing.decode(data) do
        {doc, _rest} -> {:ok, doc}
        _ -> {:error, :invalid_native_frame}
      end
    end
  end

  def close(socket) do
    :gen_tcp.close(socket)
    :ok
  end

  defp to_host(host) when is_binary(host), do: {:ok, String.to_charlist(host)}
  defp to_host(host) when is_list(host), do: {:ok, host}
  defp to_host(_), do: {:error, :invalid_host}
end
