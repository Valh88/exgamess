defmodule ExGames.DrainTest do
  @moduledoc """
  Фаза 3 плана прод-минимума: плановое опустошение ноды
  (`ExGames.Runtime.Drain`) — закрытие комнат 4001, отказ матчмейкера,
  идемпотентность. Флаг сбрасывается после каждого теста (`Drain.reset/0`).
  """

  use ExUnit.Case, async: false

  alias ExGames.Room.Server
  alias ExGames.Rooms
  alias ExGames.Runtime.Drain
  alias ExGames.Test.FakeTransport

  setup do
    on_exit(fn -> Drain.reset() end)
    :ok
  end

  test "drain closes rooms with 4001 and empties the registry" do
    {:ok, room_id} = Rooms.start(ExGames.Test.Room)
    sid = ExGames.Id.session_id()
    assert :ok = Server.reserve_seat(room_id, sid, %{}, %{})
    {transport, _join, _state} = FakeTransport.attach!(room_id, sid)

    assert :ok = Drain.drain(2000)

    # комната остановлена, транспорт получил закрытие и завершился
    refute Rooms.alive?(room_id)
    refute Process.alive?(transport)
    assert Registry.count(ExGames.RoomRegistry) == 0
  end

  test "matchmaker refuses joins while draining, works after reset" do
    name = "drain_probe_#{System.unique_integer([:positive])}"
    :ok = ExGames.Matchmaker.define_room(name, ExGames.Test.Room)

    assert :ok = Drain.drain(500)
    assert Drain.draining?()

    assert {:error, :draining} = ExGames.Matchmaker.join_or_create(name, %{}, %{})
    assert {:error, :draining} = ExGames.Matchmaker.create(name, %{}, %{})
    assert {:error, :draining} = ExGames.Matchmaker.join(name, %{}, %{})

    Drain.reset()
    refute Drain.draining?()
    assert {:ok, _reservation} = ExGames.Matchmaker.join_or_create(name, %{}, %{})
  end

  test "drain is idempotent" do
    assert :ok = Drain.drain(500)
    assert :ok = Drain.drain(500)
    assert Drain.draining?()
  end

  test "join_by_id refuses while draining" do
    {:ok, room_id} = Rooms.start(ExGames.Test.Room)

    assert :ok = Drain.drain(500)
    assert {:error, :draining} = ExGames.Matchmaker.join_by_id(room_id, %{}, %{})
  end
end
