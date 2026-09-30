defmodule ExGames.GameLogic.Adapter do
  @moduledoc """
  Контракт адаптера игровой логики. Реализован адаптерами:

    * `ExGames.GameLogic.Adapters.Elixir` — in-process Elixir-модуль;
    * `ExGames.GameLogic.Adapters.Port` — нативный процесс по stdio;
    * `ExGames.GameLogic.Adapters.TCP` — нативный процесс по TCP.

  Новый транспорт (NIF/Rustler, distributed node, WASM...) — это новая
  реализация этого behaviour; ядро и комнаты изменений не требуют.
  """

  @callback start_link(ExGames.GameLogic.opts()) ::
              {:ok, handle :: term()} | {:error, term()}

  @callback call(
              handle :: term(),
              fn_name :: String.t(),
              args :: [term()],
              ExGames.GameLogic.state()
            ) ::
              {:ok, result :: term(), ExGames.GameLogic.state()} | {:error, term()}

  # {:ok, result, state} — факультативный результат тика: его читает
  # внешний драйвер тиков (напр. мост ExGames.Room.Logics.Lua) как список
  # эффектов; авто-тик самого Server результат отбрасывает.
  @callback tick(handle :: term(), dt_ms :: non_neg_integer(), ExGames.GameLogic.state()) ::
              {:ok, ExGames.GameLogic.state()}
              | {:ok, result :: term(), ExGames.GameLogic.state()}
              | {:error, term()}

  @callback stop(handle :: term()) :: :ok
end
