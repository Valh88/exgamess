defmodule ExGamesWebWeb.GatewaySocket do
  @moduledoc """
  WebSocket-сокет мультиплексирования (`GET /ws`): несколько комнат одного
  клиента на одном соединении.

  Ядро — `ExGames.Room.Gateway` (это состояние сокета); сюда приходит только
  сеть:

    * `room_enter` — вход в комнату (attach по брони либо reattach по
      `reconnection_token`); рукопожатие и кадры комнаты приходят обратно
      в `mux`-конвертах с `room_id`;
    * `mux {r, f}` — внутренний кадр клиента маршрутизируется в комнату
      как есть (wrapнутый `leave_room` комната обрабатывает сама и закрывает
      канал кадром `mux_closed`);
    * ping — эхо на уровне сокета (keepalive соединения; per-room RTT
      ходит wrapнутыми ping'ами как обычно).

  Закрытие канала (`mux_closed` — кик, комната закрылась, отказ входа) не
  закрывает сокет. Обрыв сокета убивает каналы-прокси (они мониторят этот
  процесс): комнаты видят DOWN и держат reconnect-слоты — повторный вход
  тем же `room_enter` с токеном. Старый сервер и старый клиент друг друга
  не понимают: `room_enter`/`mux` требуют протокол с опкодами 23/25/26.
  """

  @behaviour WebSock

  require Logger

  alias ExGames.Room.Gateway
  alias ExGames.Wire

  @impl true
  def init(_mount), do: {:ok, Gateway.new()}

  @impl true
  def handle_in({data, opcode: :binary}, %Gateway{} = state) do
    case Wire.decode(data) do
      {:ok, {:room_enter, %{"room_id" => room_id, "session_id" => session_id} = payload}} ->
        token = payload["reconnection_token"]

        case Gateway.enter(state, room_id, session_id, token) do
          {:ok, state} ->
            {:ok, state}

          {:error, :already_entered} ->
            frame = Wire.encode(:mux_closed, {room_id, 522, "already entered"})
            {:push, [{:binary, frame}], state}
        end

      {:ok, {:room_enter, _malformed}} ->
        frame = Wire.encode(:error, %{code: 526, message: "malformed room_enter"})
        {:push, [{:binary, frame}], state}

      {:ok, {:mux, room_id, inner}} ->
        :ok = Gateway.route(state, room_id, inner)
        {:ok, state}

      # keepalive/RTT соединения: эхо без состояния (часы комнаты — wrapнутые ping'и)
      {:ok, {:ping}} ->
        {:push, [{:binary, data}], state}

      {:ok, {:ping, _payload}} ->
        {:push, [{:binary, data}], state}

      # голый leave_room/join_room на уровне сокета вне mux — протоколу
      # мультиплексирования не адресованы, игнорируем
      {:ok, _other} ->
        {:ok, state}

      {:error, :invalid_frame} ->
        frame = Wire.encode(:error, %{code: 522, message: "invalid frame"})

        # 4002 — ошибка/кик (коды закрытия согласованы с протоколом)
        {:stop, :normal, 4002, [{:binary, frame}], state}
    end
  end

  def handle_in({_data, opcode: :text}, state) do
    # текстовые кадры протоколом не предусмотрены
    Logger.warning("[ex_games_web] gateway: text frame ignored")
    {:ok, state}
  end

  @impl true
  def handle_info(msg, %Gateway{} = state) do
    {frames, state} = Gateway.handle_msg(state, msg)

    case frames do
      [] -> {:ok, state}
      _ -> {:push, Enum.map(frames, &{:binary, &1}), state}
    end
  end

  @impl true
  # обрыв транспорта: каналы-прокси мониторят этот процесс и выходят сами,
  # комнаты уводят сессии в reconnect-слоты; согласованный уход из комнаты
  # клиент выражает wrapнутым leave_room
  def terminate(_reason, _state), do: :ok
end
