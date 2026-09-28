defmodule ExGamesWeb.Test.WsClient do
  @moduledoc """
  Минимальный WS-клиент для интеграционных тестов транспорта
  (mint_web_socket). Копит декодированные кадры протокола, отдаёт их тесту
  через `wait_frame/2`.
  """

  use GenServer, restart: :temporary

  alias ExGames.Wire

  defstruct [:conn, :ref, :websocket, buffer: [], waiters: [], closed: nil]

  # -------------------------------------------------------------------------
  # API (вызывается из тестового процесса)
  # -------------------------------------------------------------------------

  def start_link(base, room_id, session_id, reconnection_token \\ nil) do
    GenServer.start_link(__MODULE__, {base, room_id, session_id, reconnection_token})
  end

  def stop(client), do: GenServer.stop(client, :normal)

  def send_binary(client, frame) do
    GenServer.cast(client, {:send_binary, frame})
  end

  @doc """
  Ждёт кадр заданного вида (kind — кортеж, совпадающий по первому элементу
  и, при map-элементе, по подмножеству ключей). Неподошедшие кадры
  возвращаются обратно в буфер.
  """
  def wait_frame(client, kind, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_frame(client, kind, deadline, [])
  end

  defp do_wait_frame(client, kind, deadline, skipped) do
    case GenServer.call(client, :pop_frame) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          GenServer.cast(client, {:push_back, Enum.reverse(skipped)})
          raise "frame #{inspect(kind)} did not arrive"
        end

        Process.sleep(20)
        do_wait_frame(client, kind, deadline, skipped)

      frame ->
        if frame_kind_matches?(frame, kind) do
          GenServer.cast(client, {:push_back, Enum.reverse(skipped)})
          frame
        else
          do_wait_frame(client, kind, deadline, [frame | skipped])
        end
    end
  end

  @doc "Ждёт кадр, удовлетворяющий предикату; неподошедшие возвращаются в буфер."
  def wait_where(client, predicate, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_where(client, predicate, deadline, [])
  end

  @doc """
  Ждёт WS close-кадр сервера, возвращает `{code, reason}`. Таймаут означает,
  что соединение оборвалось без согласования закрытия (краш/аборт).
  """
  def wait_close(client, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_close(client, deadline)
  end

  defp do_wait_close(client, deadline) do
    case GenServer.call(client, :get_closed) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("close frame did not arrive")

        Process.sleep(20)
        do_wait_close(client, deadline)

      closed ->
        closed
    end
  end

  defp do_wait_where(client, predicate, deadline, skipped) do
    case GenServer.call(client, :pop_frame) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          GenServer.cast(client, {:push_back, Enum.reverse(skipped)})
          raise "matching frame did not arrive"
        end

        Process.sleep(20)
        do_wait_where(client, predicate, deadline, skipped)

      frame ->
        if predicate.(frame) do
          GenServer.cast(client, {:push_back, Enum.reverse(skipped)})
          frame
        else
          do_wait_where(client, predicate, deadline, [frame | skipped])
        end
    end
  end

  defp frame_kind_matches?(_frame, :any), do: true

  defp frame_kind_matches?(frame, kind) when is_atom(kind) do
    elem(frame, 0) == kind
  end

  # {kind, value} — value сверяется с elem(1); для {:room_data, type, payload}
  # payload дополнительно проверяется на подмножество ключей.
  defp frame_kind_matches?(frame, {kind, value}) when is_map(value) and is_map(elem(frame, 2)) do
    elem(frame, 0) == kind and MapSet.subset?(MapSet.new(value), MapSet.new(elem(frame, 2)))
  end

  defp frame_kind_matches?(frame, {kind, value}) do
    match?({^kind, ^value}, frame) or (elem(frame, 0) == kind and elem(frame, 1) == value)
  end

  # -------------------------------------------------------------------------
  # Callbacks
  # -------------------------------------------------------------------------

  @impl true
  def init({base, room_id, session_id, reconnection_token}) do
    uri = URI.parse(base)
    path = "/ws/#{room_id}?sessionId=#{session_id}"

    path =
      if reconnection_token,
        do: path <> "&reconnectionToken=#{reconnection_token}",
        else: path

    with {:ok, conn} <- Mint.HTTP.connect(:http, uri.host, uri.port),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, []),
         {:ok, conn, responses} = receive_stream(conn),
         [{:status, ^ref, status}, {:headers, ^ref, resp_headers} | _] = responses,
         {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, resp_headers) do
      state = %__MODULE__{conn: conn, ref: ref, websocket: websocket}

      # кадр может прийти в том же TCP-пакете, что и 101-ответ апгрейда:
      # mint отдаёт хвост пакета как {:data, ref, data} в этом же stream-вызове
      state =
        responses
        |> Enum.flat_map(fn
          {:data, ^ref, data} -> [data]
          _ -> []
        end)
        |> Enum.reduce(state, &decode_data(&1, &2))

      {:ok, state}
    else
      {:error, error} -> {:stop, error}
      error -> {:stop, error}
    end
  end

  defp decode_data(data, %__MODULE__{} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        %__MODULE__{state | websocket: websocket} |> ingest_frames(frames)

      {:error, _websocket, _error} ->
        state
    end
  end

  defp ingest_frames(state, frames) do
    Enum.reduce(frames, state, fn
      {:binary, ws_data}, %__MODULE__{} = st ->
        case ws_data |> IO.iodata_to_binary() |> Wire.decode() do
          {:ok, frame} -> %{st | buffer: st.buffer ++ [frame]}
          _ -> st
        end

      {:close, code, reason}, %__MODULE__{} = st ->
        %{st | closed: {code || 1005, reason || ""}}

      _other, st ->
        st
    end)
  end

  defp receive_stream(conn) do
    receive do
      message -> Mint.WebSocket.stream(conn, message)
    after
      3000 -> {:error, :upgrade_timeout}
    end
  end

  @impl true
  def handle_call(:pop_frame, _from, %__MODULE__{buffer: []} = state) do
    {:reply, nil, state}
  end

  def handle_call(:pop_frame, _from, %__MODULE__{buffer: [frame | rest]} = state) do
    {:reply, frame, %__MODULE__{state | buffer: rest}}
  end

  def handle_call(:get_closed, _from, %__MODULE__{} = state) do
    {:reply, state.closed, state}
  end

  def handle_cast({:push_back, frames}, %__MODULE__{} = state) do
    {:noreply, %__MODULE__{state | buffer: frames ++ state.buffer}}
  end

  @impl true
  def handle_cast({:send_binary, frame}, %__MODULE__{} = state) do
    {:ok, websocket, data} = Mint.WebSocket.encode(state.websocket, {:binary, frame})
    {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, data)
    {:noreply, %__MODULE__{state | conn: conn, websocket: websocket}}
  end

  @impl true
  def handle_info(message, %__MODULE__{} = state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %__MODULE__{state | conn: conn})

      {:error, conn, _error, responses} ->
        handle_responses(responses, %__MODULE__{state | conn: conn})

      :unknown ->
        {:noreply, state}
    end
  end

  defp handle_responses([], state), do: {:noreply, state}

  defp handle_responses([{:data, ref, data} | rest], %__MODULE__{ref: ref} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        handle_responses(rest, state |> Map.put(:websocket, websocket) |> ingest_frames(frames))

      {:error, _websocket, _error} ->
        {:stop, :decode_error, state}
    end
  end

  defp handle_responses([_other | rest], state), do: handle_responses(rest, state)
end
