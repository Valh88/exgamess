defmodule ArenaExample.Boot do
  @moduledoc false

  use GenServer

  require Logger

  def start_link(_arg), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    :ok = ExGames.Matchmaker.define_room("chat", ExGames.Rooms.Chat, filter_by: ["channel"])
    :ok = ExGames.Matchmaker.define_room("lobby", ExGames.Rooms.Lobby)
    :ok = ExGames.Matchmaker.define_room("queue", ArenaExample.QueueRoom)

    :ok =
      ExGames.Matchmaker.define_room("arena", ArenaExample.ArenaRoom, filter_by: ["mode"])

    {:ok, _lobby_id} =
      ExGames.Matchmaker.join_or_create("lobby", %{}, %{})

    Logger.info("[arena_example] rooms registered: chat, lobby, queue, arena")
    {:ok, %{}}
  end
end
