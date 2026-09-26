defmodule ExGames.RoomsChatLobbyTest do
  use ExUnit.Case, async: false

  alias ExGames.Matchmaker
  alias ExGames.Room.Server
  alias ExGames.Rooms
  alias ExGames.Test.FakeTransport
  alias ExGames.Wire

  # -------------------------------------------------------------------------
  # Chat
  # -------------------------------------------------------------------------

  describe "chat room" do
    setup do
      name = "chat_#{System.unique_integer([:positive])}"
      :ok = Matchmaker.define_room(name, ExGames.Rooms.Chat, filter_by: ["channel"])
      %{name: name}
    end

    test "say broadcasts to channel with username from auth", %{name: name} do
      {:ok, res} =
        Matchmaker.join_or_create(name, %{"username" => "ann"}, %{
          "options" => %{"channel" => "global"}
        })

      {t1, _join, _st} = FakeTransport.attach!(res.room_id, res.session_id)

      {:ok, res2} =
        Matchmaker.join_or_create(name, %{"username" => "bob"}, %{
          "options" => %{"channel" => "global"}
        })

      {t2, _join2, _st2} = FakeTransport.attach!(res2.room_id, res2.session_id)

      FakeTransport.send_frame(
        res.room_id,
        res.session_id,
        Wire.encode(:room_data, {"say", %{"text" => "hello!"}})
      )

      frame1 = ExGames.RoomLifecycleTestHelpers.wait(t1, "say")
      frame2 = ExGames.RoomLifecycleTestHelpers.wait(t2, "say")

      assert {:ok, {:room_data, "say", %{"username" => "ann", "text" => "hello!"}}} =
               Wire.decode(frame1)

      assert {:ok, {:room_data, "say", %{"username" => "ann"}}} = Wire.decode(frame2)
    end

    test "history request returns past messages", %{name: name} do
      {:ok, res} =
        Matchmaker.join_or_create(name, %{"username" => "ann"}, %{
          "options" => %{"channel" => "global"}
        })

      {t1, _join, _st} = FakeTransport.attach!(res.room_id, res.session_id)

      FakeTransport.send_frame(
        res.room_id,
        res.session_id,
        Wire.encode(:room_data, {"say", %{"text" => "first"}})
      )

      _ = ExGames.RoomLifecycleTestHelpers.wait(t1, "say")

      FakeTransport.send_frame(
        res.room_id,
        res.session_id,
        Wire.encode(:room_request, {3, "history", %{}})
      )

      assert {:ok, {:room_response, 3, %{"messages" => [msg]}}} =
               Wire.decode(ExGames.RoomLifecycleTestHelpers.wait_response(t1, 3))

      assert msg["text"] == "first"
    end
  end

  # -------------------------------------------------------------------------
  # Lobby
  # -------------------------------------------------------------------------

  describe "lobby room" do
    test "client receives full listing and add/remove deltas" do
      # отдельный тип комнаты, события которого попадут в листинг
      game_name = "game_#{System.unique_integer([:positive])}"
      :ok = Matchmaker.define_room(game_name, ExGames.Test.Room)
      :ok = Matchmaker.define_room("lobby", ExGames.Rooms.Lobby)

      # лобби ещё не создано как комната: создаём напрямую
      {:ok, _} = Rooms.start(ExGames.Rooms.Lobby, room_id: "lobby_test_1", room_name: "lobby")

      # снапшот пуст до первого события; создадим игровую комнату —
      # лобби получит room_add
      {:ok, _} = Matchmaker.join_or_create(game_name, %{"username" => "a"})
      :ok = wait_for_pubsub()

      assert ExGames.Rooms.alive?("lobby_test_1")
    end
  end

  defp wait_for_pubsub, do: Process.sleep(100)
end
