defmodule ExGames.Account.SaveTest do
  # Облачные сохранения: upsert слотов, чтение/список/удаление, изоляция по user.

  use ExGames.Account.DataCase

  alias ExGames.Account

  defp register_user!(username) do
    {:ok, user} = Account.register(%{"username" => username, "password" => "secret123"})
    user.id
  end

  test "save + get roundtrip, кириллица и вложенность сохраняются" do
    uid = register_user!("s_#{System.unique_integer([:positive])}")
    payload = %{"level" => 3, "note" => "привет мир", "pos" => %{"x" => 1, "y" => 2}}

    assert {:ok, save} = Account.save_data(uid, "world1", payload)
    assert save.key == "world1"
    assert {:ok, ^payload} = Account.get_save(uid, "world1")
  end

  test "повторный save в тот же слот перезаписывает payload" do
    uid = register_user!("s_#{System.unique_integer([:positive])}")

    {:ok, _} = Account.save_data(uid, "slot", %{"v" => 1})
    {:ok, _} = Account.save_data(uid, "slot", %{"v" => 2, "extra" => true})

    assert {:ok, %{"v" => 2, "extra" => true}} = Account.get_save(uid, "slot")
    assert [%{key: "slot"}] = Account.list_saves(uid)
  end

  test "слоты изолированы между пользователями" do
    a = register_user!("s_#{System.unique_integer([:positive])}")
    b = register_user!("s_#{System.unique_integer([:positive])}")

    {:ok, _} = Account.save_data(a, "slot", %{"owner" => "a"})

    assert {:error, :not_found} = Account.get_save(b, "slot")
    assert [] = Account.list_saves(b)
  end

  test "list_saves возвращает ключи без payload" do
    uid = register_user!("s_#{System.unique_integer([:positive])}")

    {:ok, _} = Account.save_data(uid, "alpha", %{"v" => 1})
    {:ok, _} = Account.save_data(uid, "beta", %{"v" => 2})

    slots = Account.list_saves(uid)
    assert Enum.map(slots, & &1.key) |> Enum.sort() == ["alpha", "beta"]
    refute Map.has_key?(hd(slots), :payload)
  end

  test "delete: слот исчезает, повторный delete — not_found" do
    uid = register_user!("s_#{System.unique_integer([:positive])}")
    {:ok, _} = Account.save_data(uid, "slot", %{"v" => 1})

    assert :ok = Account.delete_save(uid, "slot")
    assert {:error, :not_found} = Account.get_save(uid, "slot")
    assert {:error, :not_found} = Account.delete_save(uid, "slot")
  end

  test "валидация: пустой ключ и не-map payload отклоняются" do
    uid = register_user!("s_#{System.unique_integer([:positive])}")

    assert {:error, _} = Account.save_data(uid, "", %{"v" => 1})
    assert {:error, _} = Account.save_data(uid, "slot", "not-a-map")
  end
end
