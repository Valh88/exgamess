defmodule ExGames.GameLogic.Adapters.Native do
  @moduledoc """
  Общая обвязка нативных адаптеров (Port и TCP).

  Транспорт реализует один blocking-вызов:

      exchange(handle, doc :: map(), timeout) :: {:ok, doc :: map()} | {:error, term()}

  Протокол в обе стороны — msgpack-документ с u32 length-prefix
  (`{:packet, 4}` / `{:packet, :raw, 4}`), состояние игры передаётся
  в каждом запросе (владелец состояния — комната, краш нативного
  процесса не теряет игру).
  """


  defmacro __using__(_opts) do
    quote do
      @behaviour ExGames.GameLogic.Adapter

      @doc false
      @impl true
      def start_link(opts) do
        init_timeout = Keyword.get(opts, :init_timeout, 5_000)

        with {:ok, handle} <- open(opts),
             {:ok, %{"ok" => true, "state" => state}} <-
               exchange(handle, %{"op" => "init", "args" => Keyword.get(opts, :args, [])},
                 init_timeout
               ) do
          {:ok, %{transport: __MODULE__, handle: handle, state: state}}
        else
          {:ok, %{"ok" => false, "error" => reason}} -> {:error, reason}
          {:error, _} = err -> err
        end
      end

      @doc false
      @impl true
      def call(handle, fn_name, args, state) do
        doc = %{"op" => "call", "fn" => fn_name, "args" => args, "state" => state}

        case exchange(handle, doc, default_timeout()) do
          {:ok, %{"ok" => true, "result" => result, "state" => new_state}} ->
            {:ok, result, new_state}

          {:ok, %{"ok" => false, "error" => reason}} ->
            {:error, reason}

          {:error, _} = err ->
            err
        end
      end

      @doc false
      @impl true
      def tick(handle, dt_ms, state) do
        doc = %{"op" => "tick", "dt" => dt_ms, "state" => state}

        case exchange(handle, doc, default_timeout()) do
          {:ok, %{"ok" => true, "state" => new_state}} -> {:ok, new_state}
          {:ok, %{"ok" => false, "error" => reason}} -> {:error, reason}
          {:error, _} = err -> err
        end
      end

      @doc false
      @impl true
      def stop(handle), do: close(handle)

      defp default_timeout, do: 5_000
      defoverridable start_link: 1, call: 4, tick: 3, stop: 1
    end
  end
end
