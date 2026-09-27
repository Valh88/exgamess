defmodule ExGames.Room.StateDiffTest do
  use ExUnit.Case, async: true

  alias ExGames.Room.StateDiff

  test "no changes → empty ops" do
    state = %{"a" => 1, "b" => %{"c" => "x"}, "l" => [1, 2]}
    assert [] = StateDiff.diff(state, state)
  end

  test "nested set produces one op with full path" do
    old = %{"players" => %{"s1" => %{"x" => 0, "y" => 0}}}
    new = put_in(old, ["players", "s1", "x"], 10)

    assert [%{"p" => ["players", "s1", "x"], "v" => 10}] = StateDiff.diff(old, new)
  end

  test "added key is a set, removed key is a delete" do
    old = %{"keep" => 1, "gone" => %{"deep" => 2}}
    new = %{"keep" => 1, "added" => 3}

    ops = StateDiff.diff(old, new)

    assert %{"p" => ["added"], "v" => 3} in ops
    assert %{"p" => ["gone"], "d" => true} in ops
    assert length(ops) == 2
  end

  test "value changed back is not in the patch" do
    old = %{"x" => 1}
    mid = %{"x" => 2}
    new = %{"x" => 1}

    assert [] = StateDiff.diff(old, new)
    refute [] == StateDiff.diff(mid, new)
  end

  test "lists are replaced atomically" do
    old = %{"l" => [1, 2, 3]}
    new = %{"l" => [1, 2]}

    assert [%{"p" => ["l"], "v" => [1, 2]}] = StateDiff.diff(old, new)
  end

  test "non-map root is a root replace" do
    assert [%{"p" => [], "v" => 42}] = StateDiff.diff(%{"a" => 1}, 42)
    assert [%{"p" => [], "v" => %{"a" => 1}}] = StateDiff.diff(42, %{"a" => 1})
  end

  test "unicode keys survive" do
    old = %{"игроки" => %{"аня" => 1}}
    new = put_in(old, ["игроки", "аня"], 2)

    assert [%{"p" => ["игроки", "аня"], "v" => 2}] = StateDiff.diff(old, new)
  end

  test "apply is the inverse of diff" do
    old = %{"players" => %{"s1" => %{"x" => 0}}, "l" => [1], "gone" => 9}
    new = %{"players" => %{"s1" => %{"x" => 5, "hp" => 3}}, "l" => [1, 2], "added" => true}

    ops = StateDiff.diff(old, new)
    assert StateDiff.apply(old, ops) == new
  end

  test "apply creates missing intermediate nodes" do
    assert StateDiff.apply(%{}, [%{"p" => ["a", "b"], "v" => 1}]) == %{"a" => %{"b" => 1}}
  end

  test "apply delete of root yields nil" do
    assert StateDiff.apply(%{"a" => 1}, [%{"p" => [], "d" => true}]) == nil
  end

  test "wire roundtrip via msgpack-like map ops" do
    ops = [%{"p" => ["игрок", "очко"], "v" => 5}, %{"p" => ["мусор"], "d" => true}]
    state = %{"игрок" => %{"очко" => 1}, "мусор" => 2}

    assert StateDiff.apply(state, ops) == %{"игрок" => %{"очко" => 5}}
  end
end
