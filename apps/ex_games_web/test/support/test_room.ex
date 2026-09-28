defmodule ExGamesWeb.Test.Room do
  @moduledoc false
  # Тестовая комната для веб-интеграционных тестов (свой test/support
  # у каждого umbrella-приложения).

  use ExGames.Room, max_clients: 2, patch_rate: 20

  @impl true
  def room_init(_options, _room), do: {:ok, %{events: [], ticks: 0}}

  @impl true
  def handle_join(room, client, _auth, state) do
    broadcast(room, "join", %{"session_id" => client.session_id})
    {:ok, %{state | events: [{:join, client.session_id} | state.events]}}
  end

  @impl true
  def handle_leave(room, client, _reason, state) do
    broadcast(room, "left", %{"session_id" => client.session_id})
    {:ok, %{state | events: [{:leave, client.session_id} | state.events]}}
  end

  @impl true
  def handle_tick(_elapsed, state), do: {:ok, %{state | ticks: state.ticks + 1}}

  message "echo", payload, room, _client, state do
    broadcast(room, "echo", payload)
    {:ok, state}
  end

  request "whoami", _payload, _room, client, state do
    {:reply, %{"session_id" => client.session_id}, state}
  end
end
