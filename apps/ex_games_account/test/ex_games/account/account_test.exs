defmodule ExGames.AccountTest do
  use ExGames.Account.DataCase, async: true

  alias ExGames.Account

  @valid_attrs %{"username" => "ann", "password" => "secret123"}

  describe "register/1" do
    test "creates user with player role" do
      assert {:ok, user} = Account.register(@valid_attrs)
      assert user.username == "ann"
      assert Account.has_role?(user, :player)
      refute Account.has_role?(user, :admin)
    end

    test "rejects duplicate username" do
      assert {:ok, _} = Account.register(@valid_attrs)
      assert {:error, errors} = Account.register(@valid_attrs)
      assert errors["username"]
    end

    test "rejects short password and bad username" do
      assert {:error, errors} = Account.register(%{"username" => "a", "password" => "secret123"})
      assert errors["username"]

      assert {:error, errors} = Account.register(%{"username" => "ann2", "password" => "12"})
      assert errors["password"]
    end
  end

  describe "login/2 and authenticate/1" do
    test "returns token that authenticates" do
      {:ok, user} = Account.register(@valid_attrs)

      assert {:ok, {:token, token, user}} = Account.login("ann", "secret123")
      assert is_binary(token)

      assert {:ok, authed} = Account.authenticate(token)
      assert authed.id == user.id
      assert Account.has_role?(authed, :player)
    end

    test "rejects bad password" do
      {:ok, _} = Account.register(@valid_attrs)
      assert {:error, :bad_credentials} = Account.login("ann", "wrong-pass")
    end

    test "rejects unknown user with same error" do
      assert {:error, :bad_credentials} = Account.login("ghost", "whatever")
    end

    test "invalid token is rejected" do
      assert {:error, _} = Account.authenticate("garbage.token.value")
    end
  end

  describe "roles" do
    test "grant and revoke" do
      {:ok, user} = Account.register(@valid_attrs)

      assert {:ok, _role, _} = Account.grant_role(user, :moderator)

      # перечитываем из БД: assoc в памяти устарел после grant
      {:ok, fresh} = Account.fetch_user("ann")
      assert Account.has_role?(fresh, :moderator)

      :ok = Account.revoke_role(fresh, :moderator)
      {:ok, fresh} = Account.fetch_user("ann")
      refute Account.has_role?(fresh, :moderator)
    end
  end

  describe "bans" do
    test "banned user cannot authenticate" do
      {:ok, user} = Account.register(@valid_attrs)
      {:ok, {:token, token, _user}} = Account.login("ann", "secret123")

      {:ok, banned} = Account.ban(user, "cheating")
      assert banned.banned_at
      assert {:error, :banned} = Account.authenticate(token)
      assert {:error, :banned} = Account.login("ann", "secret123")

      {:ok, unbanned} = Account.unban(banned)
      refute unbanned.banned_at
      assert {:ok, _} = Account.authenticate(token)
    end
  end
end
