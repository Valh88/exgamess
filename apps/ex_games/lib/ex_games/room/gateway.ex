defmodule ExGames.Room.Gateway do
  @moduledoc """
  Ядро мультиплексирования: несколько комнат одного клиента на одном
  WebSocket-сокете (`GET /ws`, шелл `ExGamesWebWeb.GatewaySocket`).

  Модуль — не процесс: функции работают над состоянием `%t{}`, которое
  живёт в процессе транспорта (WebSock-шелл или тест). На каждую пару
  «gateway × комната» спавнится канал-прокси `ExGames.Room.Gateway.Proxy`,
  прикрепляющийся к комнате как обычный транспорт.

  Поток кадра клиента → комнаты:

      handle_in (бинарный кадр)
        {:room_enter, %{"room_id", "session_id", "reconnection_token"?}} → enter/4
        {:mux, room_id, inner} → route/3 → Server.client_frame/3 (напрямую,
          внутренний кадр не декодируется; wrapнутый leave_room комната
          обрабатывает как обычно и сама закрывает канал через closed)

  Поток кадра комнаты → клиента: сообщения прокси переводятся
  `handle_msg/2` в сетевые кадры:

      {:channel_frame, room_id, frame}    → mux {r, f}
      {:channel_closed, room_id, code, message} → mux_closed {r, code, message}
      {:channel_error, room_id, reason}   → mux_closed (отказ входа)

  Закрытие канала не закрывает сокет: кик/ушедшая комната бьёт только
  по своему `room_id`. Обрыв сокета убивает прокси (те мониторят
  транспорт) — комнаты видят DOWN и держат reconnect-слоты, повторный
  вход идёт `room_enter` с `reconnection_token` (reattach, ротация токена).

  Повторный `room_enter` в ту же комнату на одном сокете отклоняется
  (`{:error, :already_entered}`).
  """

  alias ExGames.Room.Gateway.Channel
  alias ExGames.Room.Gateway.Proxy
  alias ExGames.Room.Server
  alias ExGames.Wire

  defstruct channels: %{}

  @type t :: %__MODULE__{channels: %{ExGames.Id.id() => Channel.t()}}

  @doc "Состояние нового gateway."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Вход в комнату: спавнит канал-прокси (из процесса транспорта) и
  мониторит его. `reconnection_token` не задан — attach по брони, задан —
  reattach в reconnect-слот.
  """
  @spec enter(t(), ExGames.Id.id(), ExGames.Id.id(), ExGames.Id.id() | nil) ::
          {:ok, t()} | {:error, :already_entered}
  def enter(%__MODULE__{} = state, room_id, session_id, reconnection_token \\ nil) do
    if Map.has_key?(state.channels, room_id) do
      {:error, :already_entered}
    else
      transport = self()
      proxy = spawn(fn -> Proxy.run(room_id, session_id, reconnection_token, transport) end)
      monitor = Process.monitor(proxy)

      channel = %Channel{room_id: room_id, session_id: session_id, proxy: proxy, monitor: monitor}
      {:ok, %__MODULE__{state | channels: Map.put(state.channels, room_id, channel)}}
    end
  end

  @doc """
  Маршрутизация внутреннего кадра клиента в его комнату. Кадр не
  декодируется — комната сама валидирует; канал не найден — игнор.
  """
  @spec route(t(), ExGames.Id.id(), binary()) :: :ok
  def route(%__MODULE__{} = state, room_id, inner_frame) do
    case Map.fetch(state.channels, room_id) do
      {:ok, %Channel{session_id: session_id}} ->
        Server.client_frame(room_id, session_id, inner_frame)

      :error ->
        :ok
    end
  end

  @doc """
  Перевод сообщения прокси (или его монитора) в сетевые кадры. Возвращает
  `{frames, state}` — кадры уходят в сеть, состояние обновляется в шелле.
  """
  @spec handle_msg(t(), term()) :: {[Wire.frame()], t()}
  def handle_msg(%__MODULE__{} = state, {:channel_frame, room_id, frame}) do
    {[Wire.encode(:mux, {room_id, frame})], state}
  end

  def handle_msg(%__MODULE__{} = state, {:channel_closed, room_id, code, message}) do
    {_popped, state} = pop_channel(state, room_id)
    {[Wire.encode(:mux_closed, {room_id, code, message})], state}
  end

  def handle_msg(%__MODULE__{} = state, {:channel_error, room_id, reason}) do
    {_popped, state} = pop_channel(state, room_id)
    code = if reason == :unknown_room, do: 521, else: 522

    {[Wire.encode(:mux_closed, {room_id, code, "enter failed: #{reason}"})], state}
  end

  # смерть прокси при живом канале: attach по несуществующей комнате падает
  # noproc (комната умерла), прочее — внутренняя ошибка канала
  def handle_msg(%__MODULE__{} = state, {:DOWN, ref, :process, _pid, reason})
      when is_reference(ref) do
    case find_by_monitor(state, ref) do
      nil ->
        {[], state}

      %Channel{room_id: room_id} ->
        {_popped, state} = pop_channel(state, room_id)

        {code, message} =
          case reason do
            :noproc -> {521, "room not found"}
            _ -> {4002, "channel crashed"}
          end

        {[Wire.encode(:mux_closed, {room_id, code, message})], state}
    end
  end

  def handle_msg(%__MODULE__{} = state, _other), do: {[], state}

  @doc "Идентификаторы комнат с открытыми каналами (диагностика/тесты)."
  @spec channel_ids(t()) :: [ExGames.Id.id()]
  def channel_ids(%__MODULE__{} = state), do: Map.keys(state.channels)

  # pop_channel идемпотентен: канал могли уже снять другим сообщением
  defp pop_channel(%__MODULE__{} = state, room_id) do
    case Map.pop(state.channels, room_id) do
      {nil, _} ->
        {nil, state}

      {%Channel{monitor: monitor} = channel, channels} ->
        Process.demonitor(monitor, [:flush])
        {channel, %__MODULE__{state | channels: channels}}
    end
  end

  defp find_by_monitor(%__MODULE__{} = state, ref) do
    Enum.find_value(state.channels, fn {_room_id, %Channel{} = channel} ->
      channel.monitor == ref && channel
    end)
  end
end
