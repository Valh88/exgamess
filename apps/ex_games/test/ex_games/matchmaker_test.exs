defmodule ExGames.MatchmakerTest do
  use ExUnit.Case, async: false

  alias ExGames.Matchmaker
  alias ExGames.Matchmaker.Reservation
  alias ExGames.Room.Server

  setup do
    # каждый тест — свой тип комнаты, чтобы не пересекаться
    name = "arena_#{System.unique_integer([:positive])}"
    :ok = Matchmaker.define_room(name, ExGames.Test.Room)
    %{name: name}
  end

  test "join_or_create creates a room and reserves a seat", %{name: name} do
    assert {:ok, %Reservation{} = res} = Matchmaker.join_or_create(name, %{"user" => "a"})
    assert res.room_name == name
    assert byte_size(res.room_id) == 9
    assert byte_size(res.session_id) == 12
    assert ExGames.Rooms.alive?(res.room_id)

    # место забронировано
    assert {:ok, listing} = Server.listing(res.room_id)
    assert listing.clients == 1
  end

  test "join_or_create reuses a room with free seats", %{name: name} do
    {:ok, res1} = Matchmaker.join_or_create(name, %{})
    {:ok, res2} = Matchmaker.join_or_create(name, %{})

    assert res1.room_id == res2.room_id
    assert res1.session_id != res2.session_id
  end

  test "filling max_clients creates a second room", %{name: name} do
    # ExGames.Test.Room имеет max_clients: 2
    {:ok, res1} = Matchmaker.join_or_create(name, %{})
    {:ok, res2} = Matchmaker.join_or_create(name, %{})
    {:ok, res3} = Matchmaker.join_or_create(name, %{})

    assert res3.room_id != res1.room_id
    assert res3.room_id != res2.room_id
  end

  test "filter_by separates rooms by option value", %{name: name} do
    :ok = Matchmaker.define_room(name, ExGames.Test.Room, filter_by: ["mode"])

    {:ok, a} = Matchmaker.join_or_create(name, %{}, %{"mode" => "ranked"})
    {:ok, b} = Matchmaker.join_or_create(name, %{}, %{"mode" => "casual"})

    refute a.room_id == b.room_id

    # та же mode → та же комната
    {:ok, a2} = Matchmaker.join_or_create(name, %{}, %{"mode" => "ranked"})
    assert a2.room_id == a.room_id
  end

  test "join without existing room returns :no_room", %{name: name} do
    assert {:error, :no_room} = Matchmaker.join(name, %{})
  end

  test "join attaches to existing room", %{name: name} do
    {:ok, _created} = Matchmaker.create(name, %{})
    assert {:ok, %Reservation{}} = Matchmaker.join(name, %{})
  end

  test "create always makes a new room", %{name: name} do
    {:ok, a} = Matchmaker.create(name, %{})
    {:ok, b} = Matchmaker.create(name, %{})
    refute a.room_id == b.room_id
  end

  test "unknown room type errors" do
    assert {:error, :unknown_room_type} = Matchmaker.join_or_create("never_defined", %{})
    assert {:error, :unknown_room_type} = Matchmaker.query("never_defined")
  end

  test "query lists rooms of the type", %{name: name} do
    {:ok, res} = Matchmaker.join_or_create(name, %{})

    assert {:ok, [listing]} = Matchmaker.query(name)
    assert listing.room_id == res.room_id
    assert listing.clients == 1
    assert listing.room_name == name
  end

  test "listing is cleaned up when room dies", %{name: name} do
    {:ok, res} = Matchmaker.create(name, %{})
    assert {:ok, [_]} = Matchmaker.query(name)

    ExGames.Rooms.stop(res.room_id)

    assert eventually(fn ->
             match?({:ok, []}, Matchmaker.query(name))
           end)
  end

  test "concurrent join_or_create does not lose seats or create extras", %{name: name} do
    parent = self()

    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          Matchmaker.join_or_create(name, %{"user" => "u#{i}"})
        end)
      end

    results = Task.await_many(tasks, 10_000)

    # все 10 получили бронь
    assert Enum.all?(results, &match?({:ok, %Reservation{}}, &1))

    room_ids =
      results
      |> Enum.map(fn {:ok, res} -> res.room_id end)
      |> Enum.uniq()

    session_ids =
      results
      |> Enum.map(fn {:ok, res} -> res.session_id end)
      |> Enum.uniq()

    # все сессии уникальны, комнат не больше, чем ceil(10/2)
    assert length(session_ids) == 10
    assert length(room_ids) <= 5

    send(parent, :done)
  end

  defp eventually(fun, tries \\ 50)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, tries - 1)
    end
  end
end
