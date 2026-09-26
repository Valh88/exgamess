defmodule ExGames.GameLogic.Adapters.Elixir do
  @moduledoc """
  In-process адаптер: логика — обычный Elixir-модуль с

      init(args) :: state
      call(state, fn_name, args) :: {:ok, result, state} | {:error, reason}
      tick(state, dt_ms) :: {:ok, state} | {:error, reason}

  Опции: `module: MyGame.Rules`, `args: [...]`.
  """

  @behaviour ExGames.GameLogic.Adapter

  @impl true
  def start_link(opts) do
    module = Keyword.fetch!(opts, :module)
    args = Keyword.get(opts, :args, [])

    case module.init(args) do
      state when is_map(state) or is_list(state) -> {:ok, %{module: module, state: state}}
      {:error, _} = err -> err
      other -> {:ok, %{module: module, state: other}}
    end
  end

  @impl true
  def call(handle, fn_name, args, _state) do
    case apply(handle.module, :call, [handle.state, fn_name, args]) do
      {:ok, result, new_state} -> {:ok, result, new_state}
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def tick(handle, dt_ms, _state) do
    case apply(handle.module, :tick, [handle.state, dt_ms]) do
      {:ok, new_state} -> {:ok, new_state}
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def stop(_handle), do: :ok
end
