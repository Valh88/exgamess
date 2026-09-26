defmodule ExGames.Rooms do
  @moduledoc """
  Управление комнатами: старт/остановка через `ExGames.RoomSupervisor`
  (DynamicSupervisor), поиск через `ExGames.RoomRegistry`.

  Комнаты — `:temporary`: упавшая комната не рестартует (игровое состояние
  не восстанавливаемо), её листинг подчистит матчмейкер по сигналу DOWN.
  """

  alias ExGames.Room.Server

  @typedoc "Идентификатор комнаты."
  @type room_id :: ExGames.Id.id()

  @doc """
  Стартует комнату игрового модуля `module`. Возвращает
  `{:ok, room_id}` или `{:error, reason}`.

  ## Опции

    * `:room_id` — явный id (иначе генерируется);
    * `:options` — опции создания для `room_init/2`;
    * прочие опции перекрывают настройки `use ExGames.Room`
      (`:max_clients`, `:patch_rate`, `:auto_dispose`, `:rate_limit`).
  """
  @spec start(module(), keyword()) :: {:ok, room_id()} | {:error, term()}
  def start(module, opts \\ []) do
    room_id = Keyword.get(opts, :room_id) || ExGames.Id.room_id()
    opts = Keyword.put_new(opts, :room_id, room_id)

    case DynamicSupervisor.start_child(ExGames.RoomSupervisor, {Server, opts ++ [module: module]}) do
      {:ok, _pid} -> {:ok, room_id}
      {:error, {:already_started, _pid}} -> {:error, {:already_started, room_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Находит pid комнаты по идентификатору."
  @spec lookup(room_id()) :: {:ok, pid()} | :error
  def lookup(room_id) do
    case Registry.lookup(ExGames.RoomRegistry, {:room, room_id}) do
      [] -> :error
      [{pid, _}] -> {:ok, pid}
    end
  end

  @doc "Жива ли комната."
  @spec alive?(room_id()) :: boolean()
  def alive?(room_id), do: match?({:ok, pid} when is_pid(pid), lookup(room_id))

  @doc "Закрывает комнату (клиентам уходит кадр закрытия)."
  @spec stop(room_id()) :: :ok
  def stop(room_id) do
    case lookup(room_id) do
      {:ok, pid} ->
        Process.exit(pid, {:shutdown, :dispose})
        :ok

      :error ->
        :ok
    end
  end

  @doc "Число живых комнат (диагностика/тесты)."
  @spec count() :: non_neg_integer()
  def count do
    Registry.count(ExGames.RoomRegistry)
  end
end
