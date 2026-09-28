defmodule ExGamesWebWeb.RoomSocket do
  @moduledoc """
  WebSocket-сокет комнаты (WebSock behaviour, Bandit/WebSockAdapter).

  Жизненный цикл:

    1. `init/1` — подключает сокет к забронированному месту
       (`ExGames.Room.Server.attach/4`) либо, при наличии
       `reconnection_token`, возвращает транспорт в сессию
       (`ExGames.Room.Server.reattach/4`). Комната отправляет `:join_room`
       и полный снапшот состояния (если есть) — кадры приходят сюда как
       сообщения и пушатся в сеть.
    2. `handle_in/2` — бинарные кадры клиента передаются в комнату как есть.
    3. `handle_info/2` — кадры комнаты пушатся в сеть.
    4. `terminate/2` — не-согласованный обрыв (`Server.drop/2`): клиент
       остаётся в комнате в слоте reconnection. Согласованный уход клиент
       выражает сам кадром `leave_room`.

  Клиенту уходит `{:ex_games_closed, code, message}` от комнаты при кике/
  закрытии; после него соединение закрывается этим же WS close-кодом
  (кадр ошибки уходит перед close-кадром).
  """

  @behaviour WebSock

  require Logger

  alias ExGames.Room.Server
  alias ExGames.Wire

  @impl true
  def init(%{room_id: room_id, session_id: session_id} = mount) do
    result =
      case mount do
        %{reconnection_token: token} -> Server.reattach(room_id, session_id, self(), token)
        _ -> Server.attach(room_id, session_id, self(), %{})
      end

    case result do
      {:ok, _join_frame, _state_frame} ->
        {:ok, %{room_id: room_id, session_id: session_id, closing: false}}

      {:error, reason} ->
        frame = Wire.encode(:error, %{code: 522, message: to_string(reason)})
        _ = mount
        state = %{room_id: room_id, session_id: session_id, closing: true}

        # 4002 — ошибка/кик (коды закрытия совместимы с Colyseus)
        {:stop, :normal, 4002, [{:binary, frame}], state}
    end
  end

  @impl true
  # Клиент → комната. WebSockAdapter передаёт {:binary | :text, data}.
  def handle_in({data, opcode: :binary}, %{closing: false} = state) do
    Server.client_frame(state.room_id, state.session_id, data)
    {:ok, state}
  end

  def handle_in({data, opcode: :text}, state) do
    # текстовые кадры протоколом не предусмотрены
    Logger.warning("[ex_games_web] text frame ignored (#{byte_size(data)} bytes)")
    {:ok, state}
  end

  # кадры, пришедшие после начала закрытия (клиент не увидел close-кадр),
  # протоколу не интересны — иначе Bandit вызвал бы handle_in в неожиданном
  # состоянии
  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:ex_games_push, frame}, %{closing: false} = state) do
    {:push, [{:binary, frame}], state}
  end

  def handle_info({:ex_games_push, _frame}, state), do: {:ok, state}

  def handle_info({:ex_games_closed, code, message}, state) do
    # сообщаем клиенту код ошибки протокола и закрываем соединение тем же
    # WS close-кодом: Bandit отправит кадр ошибки, затем close-кадр
    frame = Wire.encode(:error, %{code: code, message: message})
    {:stop, :normal, code, [{:binary, frame}], %{state | closing: true}}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  # обрыв транспорта: комната сама решает (слот reconnection или remove),
  # согласованное leave уходит кадром leave_room
  def terminate(_reason, %{room_id: room_id, session_id: session_id, closing: false}) do
    Server.drop(room_id, session_id)
    :ok
  end

  # закрытие по инициативе комнаты/инициализации — комната уже всё сделала
  def terminate(_reason, _state), do: :ok
end
