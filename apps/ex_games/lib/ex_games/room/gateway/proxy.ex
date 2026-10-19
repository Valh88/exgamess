defmodule ExGames.Room.Gateway.Proxy do
  @moduledoc """
  Канал-прокси мультиплексирования: отдельный процесс на пару
  «gateway × комната».

  Комната отправляет кадры транспорту сообщениями без room_id
  (`{:ex_games_push, frame}` / `{:ex_games_closed, code, message}`), поэтому
  gateway не может сам быть транспортом нескольких комнат — источник кадра
  было бы не определить. Прокси прикрепляется к комнате как обычный
  транспорт (`Server.attach/reattach`) и пересылает всё gateway'ю, тегируя
  комнатой:

    * `{:ex_games_push, frame}` → `{:channel_frame, room_id, frame}`
    * `{:ex_games_closed, code, message}` → `{:channel_closed, room_id, code, message}`
    * отказ attach/reattach → `{:channel_error, room_id, reason}`

  Жизненный цикл:

    * мониторит процесс gateway — транспорт умер, прокси выходит; комната
      видит DOWN по своему монитору и держит reconnect-слот ровно как при
      обрыве выделенного сокета;
    * мониторит комнату — аномальная смерть комнаты без прощального
      `{:ex_games_closed, ...}` закрывает канал кодом 4001;
    * согласованное закрытие (комната прислала `{:ex_games_closed, ...}`)
      завершает прокси.

  Цикл держит пустой receive без выборок по содержимому — O(1) на сообщение,
  почтовый ящик не сканируется. Входящие кадры клиента через прокси не идут:
  gateway маршрутизирует их в комнату напрямую (`Server.client_frame/3`).
  """

  alias ExGames.Room
  alias ExGames.Room.Server

  @doc false
  @spec run(ExGames.Id.id(), ExGames.Id.id(), ExGames.Id.id() | nil, pid()) :: :ok
  def run(room_id, session_id, reconnection_token, gateway_pid) do
    gateway_ref = Process.monitor(gateway_pid)

    result =
      if reconnection_token do
        Server.reattach(room_id, session_id, self(), reconnection_token)
      else
        Server.attach(room_id, session_id, self(), %{})
      end

    case result do
      {:ok, _join_frame, _state_frame} ->
        # комната могла умереть между reply и whereis — тогда это закрытие
        room_pid = GenServer.whereis(Room.via(room_id))

        if is_nil(room_pid) do
          send(gateway_pid, {:channel_closed, room_id, 4001, "room terminated"})
          :ok
        else
          room_ref = Process.monitor(room_pid)
          loop(room_id, gateway_pid, gateway_ref, room_ref)
        end

      {:error, reason} ->
        send(gateway_pid, {:channel_error, room_id, reason})
        :ok
    end
  end

  defp loop(room_id, gateway_pid, gateway_ref, room_ref) do
    receive do
      {:ex_games_push, frame} ->
        send(gateway_pid, {:channel_frame, room_id, frame})
        loop(room_id, gateway_pid, gateway_ref, room_ref)

      {:ex_games_closed, code, message} ->
        send(gateway_pid, {:channel_closed, room_id, code, message})
        :ok

      {:DOWN, ^gateway_ref, :process, _pid, _reason} ->
        # транспорт умер: комната увидит DOWN по своему монитору и уведёт
        # сессию в reconnect-слот (или удалит — по её политике)
        :ok

      {:DOWN, ^room_ref, :process, _pid, _reason} ->
        send(gateway_pid, {:channel_closed, room_id, 4001, "room terminated"})
        :ok
    end
  end
end
