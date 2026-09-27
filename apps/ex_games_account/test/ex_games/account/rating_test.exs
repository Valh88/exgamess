defmodule ExGames.Account.RatingTest do
  # Elo-рейтинги: пересчёт исходов, счётчики, ошибки контракта.

  use ExGames.Account.DataCase

  alias ExGames.Account

  defp register_user!(username) do
    {:ok, user} = Account.register(%{"username" => username, "password" => "secret123"})
    user.id
  end

  test "no rating until first match" do
    uid = register_user!("r_#{System.unique_integer([:positive])}")
    assert :error = Account.get_rating(uid, "arena")
  end

  test "even match 1000 vs 1000 → 1016 / 984 (K=32)" do
    a = register_user!("r_#{System.unique_integer([:positive])}")
    b = register_user!("r_#{System.unique_integer([:positive])}")

    assert {:ok, %{^a => ra, ^b => rb}} = Account.record_match("arena", %{a => :win, b => :loss})

    assert ra == 1016
    assert rb == 984
    assert {:ok, 1016} = Account.get_rating(a, "arena")
    assert {:ok, 984} = Account.get_rating(b, "arena")
  end

  test "higher-rated winner gains less than lower-rated loser loses" do
    a = register_user!("r_#{System.unique_integer([:positive])}")
    b = register_user!("r_#{System.unique_integer([:positive])}")

    # a набирает рейтинг первым матчем
    {:ok, _} = Account.record_match("arena", %{a => :win, b => :loss})
    {:ok, rating_a} = Account.get_rating(a, "arena")
    {:ok, rating_b} = Account.get_rating(b, "arena")

    # a (выше рейтингом) выигрывает у b (ниже) — прирост меньше половины K
    {:ok, %{^a => na, ^b => nb}} = Account.record_match("arena", %{a => :win, b => :loss})

    assert (na - rating_a) in 4..15
    assert (rating_b - nb) in 4..15
  end

  test "draw keeps equal ratings equal" do
    a = register_user!("r_#{System.unique_integer([:positive])}")
    b = register_user!("r_#{System.unique_integer([:positive])}")

    assert {:ok, %{^a => ra, ^b => rb}} = Account.record_match("arena", %{a => :draw, b => :draw})
    assert ra == 1000
    assert rb == 1000
  end

  test "games are independent and counters accumulate" do
    uid = register_user!("r_#{System.unique_integer([:positive])}")
    other = register_user!("r_#{System.unique_integer([:positive])}")

    {:ok, _} = Account.record_match("arena", %{uid => :win, other => :loss})
    {:ok, _} = Account.record_match("chess", %{uid => :loss, other => :win})

    assert {:ok, 1016} = Account.get_rating(uid, "arena")
    assert {:ok, 984} = Account.get_rating(uid, "chess")

    row = ExGames.Account.Repo.get_by(ExGames.Account.Rating, user_id: uid, game: "arena")
    assert row.wins == 1
    assert row.losses == 0
  end

  test "unknown user rolls back the whole match" do
    a = register_user!("r_#{System.unique_integer([:positive])}")

    assert {:error, {:unknown_user, unknown}} =
             Account.record_match("arena", %{a => :win, 99_999_999 => :loss})

    assert is_integer(unknown)

    # победитель не получил рейтинг — транзакция откатилась
    assert :error = Account.get_rating(a, "arena")
  end

  test "needs at least two participants" do
    a = register_user!("r_#{System.unique_integer([:positive])}")
    assert {:error, :need_two_players} = Account.record_match("arena", %{a => :win})
  end

  test "bad outcome shape is rejected" do
    a = register_user!("r_#{System.unique_integer([:positive])}")
    b = register_user!("r_#{System.unique_integer([:positive])}")

    assert {:error, {:bad_result, _}} = Account.record_match("arena", %{a => "win", b => :loss})
  end
end
