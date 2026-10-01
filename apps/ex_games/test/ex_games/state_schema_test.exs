defmodule ExGames.StateSchemaTest do
  @moduledoc """
  Валидатор wire-документа состояния по схеме M.schema (`ExGames.Room.StateSchema`).
  """

  use ExUnit.Case, async: true

  alias ExGames.Room.StateSchema

  @schema %{
    "seq" => "number",
    "name" => "string",
    "ready" => "boolean",
    "raw" => "any",
    "users" => %{"map" => "string"},
    "history" => %{"map" => %{"text" => "string", "n" => "number"}},
    "tags" => %{"list" => "string"}
  }

  @valid %{
    "seq" => 1,
    "name" => "x",
    "ready" => false,
    "raw" => %{"k" => [1, "two", nil, %{"deep" => true}]},
    "users" => %{"a" => "b"},
    "history" => %{"1" => %{"text" => "t", "n" => 2}},
    "tags" => ["a", "b"]
  }

  test "валидный документ проходит" do
    assert :ok = StateSchema.validate(@schema, @valid)
  end

  test "отсутствующие поля ок, неизвестные — ошибка" do
    assert :ok = StateSchema.validate(@schema, %{"seq" => 1})

    assert {:error, "$.unknown: поле не объявлено в схеме"} =
             StateSchema.validate(@schema, %{"seq" => 1, "unknown" => 1})
  end

  test "nil-значение проходит против любого листа" do
    assert :ok = StateSchema.validate(@schema, %{"seq" => nil, "name" => nil, "tags" => nil})
  end

  test "не тот тип листа — ошибка с путём" do
    assert {:error, "$.seq: ожидался number, получен string"} =
             StateSchema.validate(@schema, %{"seq" => "1"})

    assert {:error, "$.users.a: ожидалась string, получен number"} =
             StateSchema.validate(@schema, %{"users" => %{"a" => 1}})

    assert {:error, "$.history.1.n: ожидался number, получен boolean"} =
             StateSchema.validate(@schema, %{"history" => %{"1" => %{"text" => "t", "n" => true}}})
  end

  test "контейнер против скаляра — ошибка" do
    assert {:error, "$.users: ожидался объект, получен string"} =
             StateSchema.validate(@schema, %{"users" => "x"})

    assert {:error, "$.tags: ожидался массив, получен object"} =
             StateSchema.validate(@schema, %{"tags" => %{"a" => 1}})
  end

  test "структура против скаляра/массива — ошибка" do
    assert {:error, _} = StateSchema.validate(@schema, %{"history" => "x"})
    assert {:error, _} = StateSchema.validate(@schema, 5)
  end

  test "nil-схема пропускает всё" do
    assert :ok = StateSchema.validate(nil, %{"что угодно" => [1, 2, 3]})
  end

  test "validate_root: пустая карта схем пропускает" do
    assert :ok = StateSchema.validate_root(%{}, %{"x" => 1})
    assert :ok = StateSchema.validate_root(nil, "даже не объект")
  end

  test "validate_root: ветки по ключам, ветки без схемы не трогаем" do
    schemas = %{"phys" => %{"pos" => "number"}}

    assert :ok =
             StateSchema.validate_root(schemas, %{
               "phys" => %{"pos" => 1},
               "misc" => %{"любой" => "документ"}
             })

    assert {:error, "$.phys.pos: ожидался number, получен string"} =
             StateSchema.validate_root(schemas, %{"phys" => %{"pos" => "bad"}})
  end

  test "validate_root: корневая схема проверяет весь документ" do
    schemas = %{nil => %{"a" => "number"}, "phys" => %{"a" => "number"}}

    assert :ok = StateSchema.validate_root(schemas, %{"a" => 1})

    assert {:error, "$.a: ожидался number, получен string"} =
             StateSchema.validate_root(schemas, %{"a" => "bad"})
  end
end
