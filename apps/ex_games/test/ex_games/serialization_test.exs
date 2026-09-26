defmodule ExGames.SerializationTest do
  use ExUnit.Case, async: true

  defmodule Player do
    @derive ExGames.Serialization
    defstruct [:name, :score]
  end

  test "structs derive to wire maps with string keys" do
    wire = ExGames.Serialization.to_wire(%Player{name: "ann", score: 5})
    assert wire == %{"name" => "ann", "score" => 5}
  end

  test "atom map keys are converted to strings" do
    wire = ExGames.Serialization.to_wire(%{:a => 1, "b" => %{c: [1, 2]}})
    assert wire == %{"a" => 1, "b" => %{"c" => [1, 2]}}
  end

  test "nested structs and lists" do
    wire =
      ExGames.Serialization.to_wire(%{
        players: [%Player{name: "a", score: 1}, %Player{name: "b", score: 2}]
      })

    assert wire == %{
             "players" => [%{"name" => "a", "score" => 1}, %{"name" => "b", "score" => 2}]
           }
  end

  test "plain values pass through" do
    assert ExGames.Serialization.to_wire(42) == 42
    assert ExGames.Serialization.to_wire("x") == "x"
    assert ExGames.Serialization.to_wire(nil) == nil
    assert ExGames.Serialization.to_wire(:ok) == :ok
  end
end
