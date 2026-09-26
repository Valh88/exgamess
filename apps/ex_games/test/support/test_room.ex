defmodule ExGames.Test.Room do
  @moduledoc false
  # Тестовая комната: собирает события в состояние, рассылает broadcast'ы.
  # Используется и в тестах ядра, и в интеграционных тестах веб-слоя.

  use ExGames.Room, max_clients: 2, patch_rate: 20

  @impl true
  def room_init(options, _room) do
    {:ok, %{events: [], options: options, ticks: 0}}
  end

  @impl true
  def handle_auth(auth_data, _options, _room) do
    if auth_data == :deny do
      {:error, :denied}
    else
      {:ok, auth_data}
    end
  end

  @impl true
  def handle_join(room, client, auth, state) do
    broadcast(room, "join", %{"session_id" => client.session_id, "auth" => auth})
    {:ok, %{state | events: [{:join, client.session_id} | state.events]}}
  end

  @impl true
  def handle_leave(room, client, reason, state) do
    broadcast(room, "left", %{"session_id" => client.session_id, "reason" => Atom.to_string(reason)})
    {:ok, %{state | events: [{:leave, client.session_id} | state.events]}}
  end

  @impl true
  def handle_tick(_elapsed, state) do
    {:ok, %{state | ticks: state.ticks + 1}}
  end

  message "echo", payload, room, client, state do
    broadcast(room, "echo", payload)
    send_to(room, client.session_id, "ack", payload)
    {:ok, state}
  end

  message "boom", _payload, _room, _client, state do
    raise "boom"
    {:ok, state}
  end

  request "whoami", _payload, _room, client, state do
    {:reply, %{"session_id" => client.session_id}, state}
  end

  request "void", _payload, _room, _client, state do
    {:ok, state}
  end
end

defmodule ExGames.Test.FakeTransport do
  @moduledoc false
  # Подставной транспорт: копит кадры в своём состоянии и умеет слать сырые
  # кадры в комнату. Используется в тестах lifecycle ядра.

  def start_link do
    pid = spawn_link(fn -> loop([]) end)
    {:ok, pid}
  end

  def attach!(room_id, session_id) do
    {:ok, transport} = start_link()
    {:ok, join_frame, state_frame} = ExGames.Room.Server.attach(room_id, session_id, transport, %{})
    {transport, join_frame, state_frame}
  end

  def frames(transport, timeout \\ 500) do
    ref = make_ref()
    send(transport, {:collect, self(), ref})

    receive do
      {^ref, frames} -> frames
    after
      timeout -> []
    end
  end

  def send_frame(room_id, session_id, frame) do
    ExGames.Room.Server.client_frame(room_id, session_id, frame)
  end

  defp loop(acc) do
    receive do
      {:collect, reply_to, ref} ->
        send(reply_to, {ref, Enum.reverse(acc)})
        loop(acc)

      {:ex_games_push, frame} ->
        loop([frame | acc])

      {:ex_games_closed, _code, _message} ->
        :ok

      :stop ->
        :ok

      _other ->
        loop(acc)
    end
  end
end
