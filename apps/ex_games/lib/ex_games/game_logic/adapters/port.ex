defmodule ExGames.GameLogic.Adapters.Port do
  @moduledoc """
  Нативная логика через `Port` (stdio). Владелец порта — процесс, вызвавший
  `open/1`, поэтому blocking-exchange безопасен: сообщения порта приходят
  только ему.

  Опции:

    * `command: {"priv/native/rules.exe", [args...]}` — исполняемый файл и
      аргументы (нативный бинарник, `{"python", ["rules.py"]}`, Node-скрипт
      — что угодно);
    * `args: [...]` — аргументы init-вызова логики.

  Протокол — msgpack + u32 length-prefix по stdin/stdout; тот же бинарник
  может работать и через `Adapters.TCP`, без изменения кода нативной части.
  """

  use ExGames.GameLogic.Adapters.Native

  alias ExGames.GameLogic.Framing

  def open(opts) do
    {cmd, args} = Keyword.fetch!(opts, :command)

    port =
      Port.open({:spawn_executable, to_charlist(cmd)}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:args, Enum.map(args, &to_charlist/1)}
      ])

    {:ok, port}
  end

  def exchange(port, doc, timeout) do
    Port.command(port, Framing.encode(doc))

    receive do
      {^port, {:data, data}} ->
        case Framing.decode(data) do
          {doc, _rest} -> {:ok, doc}
          _ -> {:error, :invalid_native_frame}
        end

      {^port, {:exit_status, status}} ->
        {:error, {:native_exit, status}}
    after
      timeout -> {:error, :native_timeout}
    end
  end

  def close(port) do
    Port.close(port)
    :ok
  end
end
