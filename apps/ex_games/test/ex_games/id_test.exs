defmodule ExGames.IdTest do
  use ExUnit.Case, async: true

  test "room_id is 9 url-safe chars" do
    id = ExGames.Id.room_id()
    assert String.length(id) == 9
    assert Regex.match?(~r/^[A-Za-z0-9]+$/, id)
  end

  test "session_id is 12 chars and unique" do
    ids = for _ <- 1..100, do: ExGames.Id.session_id()
    assert Enum.uniq(ids) == ids
    assert Enum.all?(ids, &(String.length(&1) == 12))
  end

  test "token is 32 chars" do
    assert String.length(ExGames.Id.token()) == 32
  end
end
