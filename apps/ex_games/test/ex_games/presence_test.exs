defmodule ExGames.PresenceTest do
  use ExUnit.Case, async: false

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
