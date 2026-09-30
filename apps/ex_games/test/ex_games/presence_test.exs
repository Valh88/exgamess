defmodule ExGames.PresenceTest do
  use ExUnit.Case, async: false

  alias ExGames.Presence
  alias ExGames.Room.Server
  alias ExGames.Rooms
  alias ExGames.Test.FakeTransport

  test "track/list/online?/untrack with events" do
    ExGames.Presence.subscribe()

    :ok = ExGames.Presence.track_user("user_1", %{"room" => "arena"})
    assert eventually(fn -> ExGames.Presence.online?("user_1") end)
    assert %{"room" => "arena"} = ExGames.Presence.list_online()["user_1"]

    assert_receive {ExGames.Presence, %{event: :join, user_id: "user_1"}}, 1000

    :ok = ExGames.Presence.untrack_user("user_1")
    assert eventually(fn -> not ExGames.Presence.online?("user_1") end)
    assert_receive {ExGames.Presence, %{event: :leave, user_id: "user_1"}}, 1000
  end

  test "presence is cleaned when tracking process dies" do
    parent = self()

    pid =
      spawn_link(fn ->
        :ok = ExGames.Presence.track_user("user_ghost", %{})
        send(parent, :tracked)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :tracked, 1000
    assert eventually(fn -> ExGames.Presence.online?("user_ghost") end)

    send(pid, :stop)
    assert eventually(fn -> not ExGames.Presence.online?("user_ghost") end)
  end

  # -------------------------------------------------------------------------
  # Трекинг из комнат: attach трекает user_id из auth, уход снимает;
  # юзер в двух комнатах остаётся онлайн после ухода из одной (dup: :auto)
  # -------------------------------------------------------------------------

  setup do
    {:ok, room_a} = Rooms.start(ExGames.Test.Room)
    {:ok, room_b} = Rooms.start(ExGames.Test.Room)
    %{room_a: room_a, room_b: room_b}
  end

  defp join!(room_id, sid, auth) do
    :ok = Server.reserve_seat(room_id, sid, auth, %{})
    FakeTransport.attach!(room_id, sid)
    sid
  end

  test "attach трекает user_id с room_id и username; kick снимает", %{room_a: room_a} do
    sid = ExGames.Id.session_id()
    join!(room_a, sid, %{"user_id" => 101, "username" => "ann"})

    assert eventually(fn -> Presence.online?("101") end)
    assert %{"room_id" => ^room_a, "username" => "ann"} = Presence.list_online()["101"]

    :ok = ExGames.Room.kick(%ExGames.Room.Handle{room_id: room_a}, sid)
    assert eventually(fn -> not Presence.online?("101") end)
  end

  test "юзер в двух комнатах: уход из одной оставляет онлайн (dup: :auto)", %{
    room_a: room_a,
    room_b: room_b
  } do
    sid_a = ExGames.Id.session_id()
    sid_b = ExGames.Id.session_id()
    join!(room_a, sid_a, %{"user_id" => 202, "username" => "bob"})
    join!(room_b, sid_b, %{"user_id" => 202, "username" => "bob"})

    assert eventually(fn -> Presence.online?("202") end)

    # уход из первой комнаты: держателем остаётся вторая
    :ok = ExGames.Room.kick(%ExGames.Room.Handle{room_id: room_a}, sid_a)

    assert eventually(fn ->
             Presence.online?("202") and Presence.list_online()["202"]["room_id"] == room_b
           end)

    :ok = ExGames.Room.kick(%ExGames.Room.Handle{room_id: room_b}, sid_b)
    assert eventually(fn -> not Presence.online?("202") end)
  end

  test "смерть комнаты снимает presence её клиентов", %{room_a: room_a} do
    sid = ExGames.Id.session_id()
    join!(room_a, sid, %{"user_id" => 303, "username" => "cara"})

    assert eventually(fn -> Presence.online?("303") end)

    Rooms.stop(room_a)
    assert eventually(fn -> not Presence.online?("303") end)
  end

  defp eventually(fun, tries \\ 50)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, tries - 1)
    end
  end
end
