defmodule ExGames.Rooms.Lobby do
  @moduledoc """
  Лобби-комната: при входе клиент получает
  полный листинг комнат, далее — дельты `room_add` / `room_update` /
  `room_remove`.

  Изменения листинга приходят через PubSub-топик
  `ExGames.Matchmaker.lobby_topic/0`, куда публикация идёт из
  `ExGames.Room.Server` при каждом изменении листинга. Multi-node ready:
  достаточно PubSub-адаптера с рассылкой между узлами.

  Клиентские сообщения:

    * `{"refresh", %{}}` — прислать полный листинг заново.

  Сообщения клиенту:

    * `{"rooms", [listing, ...]}` — полный листинг (при входе и refresh);
    * `{"room_add", listing}` / `{"room_update", listing}` /
      `{"room_remove", %{"room_id" => id}}`.
  """

  use ExGames.Room, max_clients: :infinity, patch_rate: 0

  @impl true
  def room_init(_options, room) do
    # подписка на события матчмейкера (side effect в room_init — допустимо)
    Phoenix.PubSub.subscribe(ExGames.PubSub, ExGames.Matchmaker.lobby_topic())
    {:ok, %{room: room, snapshot: %{}}}
  end

  @impl true
  def handle_join(room, _client, _auth, state) do
    send_listing(room, state.snapshot)
    {:ok, state}
  end

  message "refresh", _payload, room, _client, state do
    send_listing(room, state.snapshot)
    {:ok, state}
  end

  @impl true
  def handle_info({:ex_games, :lobby, {:update, listing}}, state) do
    id = listing.room_id
    old = Map.get(state.snapshot, id)

    cond do
      is_nil(old) ->
        broadcast(state.room, "room_add", listing)

      old != listing ->
        broadcast(state.room, "room_update", listing)

      true ->
        :unchanged
    end

    {:ok, Map.put(state, :snapshot, Map.put(state.snapshot, id, listing))}
  end

  def handle_info({:ex_games, :lobby, {:remove, room_id}}, state) do
    if Map.has_key?(state.snapshot, room_id) do
      broadcast(state.room, "room_remove", %{"room_id" => room_id})
      {:ok, Map.put(state, :snapshot, Map.delete(state.snapshot, room_id))}
    else
      {:ok, state}
    end
  end

  def handle_info(_msg, state), do: {:ok, state}

  defp send_listing(room, snapshot) do
    broadcast(room, "rooms", Map.values(snapshot))
  end
end
