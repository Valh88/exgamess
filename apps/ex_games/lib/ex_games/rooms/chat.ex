defmodule ExGames.Rooms.Chat do
  @moduledoc """
  Чат-комната (по образцу RelayRoom в Colyseus): re-broadcast сообщений
  канала + история последних сообщений.

  Каналы чата — обычные комнаты, создаваемые через матчмейкер:

      ExGames.Matchmaker.define_room("chat", ExGames.Rooms.Chat, filter_by: ["channel"])
      ExGames.Matchmaker.join_or_create("chat", auth, %{"options" => %{"channel" => "global"}})

  Клиентские сообщения:

    * `{"say", %{"text" => "..."}}` — всем в канале (клауза `say` ниже);
    * `{"whisper", %{"to" => session_id, "text" => "..."}}` — приватно.

  История отдаётся запросом `{"history", %{}}` (request/response).
  """

  use ExGames.Room, max_clients: :infinity, patch_rate: 0, rate_limit: 60

  @history_size 50

  @impl true
  def room_init(options, _room) do
    channel = Map.get(options, "channel", "global")
    {:ok, %{channel: channel, history: :queue.new(), seq: 0}}
  end

  @impl true
  def handle_join(room, client, auth, state) do
    broadcast(room, "joined", %{"session_id" => client.session_id, "username" => username(client, auth)})
    {:ok, state}
  end

  @impl true
  def handle_leave(room, client, _reason, state) do
    broadcast(room, "left", %{"session_id" => client.session_id})
    {:ok, state}
  end

  message "say", %{"text" => text}, room, client, state do
    entry = %{
      "seq" => state.seq + 1,
      "from" => client.session_id,
      "username" => username(client, client.auth),
      "text" => String.slice(text, 0, 500)
    }

    broadcast(room, "say", entry)
    {:ok, %{state | seq: entry["seq"], history: push_history(state.history, entry)}}
  end

  message "whisper", %{"to" => to, "text" => text}, room, client, state do
    send_to(room, to, "whisper", %{
      "from" => client.session_id,
      "username" => username(client, client.auth),
      "text" => String.slice(text, 0, 500)
    })

    {:ok, state}
  end

  request "history", _payload, _room, _client, state do
    {:reply, %{"channel" => state.channel, "messages" => :queue.to_list(state.history)}, state}
  end

  defp push_history(history, entry) do
    queue = :queue.in(entry, history)

    if :queue.len(queue) > @history_size do
      {{_, rest}, _} = :queue.out(queue)
      rest
    else
      queue
    end
  end

  defp username(client, auth) do
    case auth do
      %{"username" => u} when is_binary(u) -> u
      _ -> client.session_id
    end
  end
end
