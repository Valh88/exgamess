defmodule ExGames.Room.StateSchema do
  @moduledoc """
  Валидация wire-документа состояния комнаты по схеме `M.schema` Lua-скрипта.

  Схема — документ того же вида, что отдаёт request `"schema"` (и
  `mix ex_games.lua_schema`): лист — `"number" | "string" | "boolean" | "any"`,
  контейнер — `%{"map" => schema}` / `%{"list" => schema}`, структура —
  map «поле → схема» (например `{"seq" => "number", "users" => %{"map" => "string"}}`).

  Правила:

    * `nil` (у комнаты нет схемы) — документ пропускается;
    * `nil` в документе проходит против любого дескриптора (незаданное поле);
    * в структуре неизвестное поле документа — ошибка, отсутствующее — ок
      (опциональные/nullable поля скрипт может не заполнять);
    * ключи `%{"map" => …}` произвольны, значения проверяются по вложенной схеме.

  Используется гейтом `set_state` в `ExGames.Room.Server` (отклонить чужой
  документ, ломающий схему скрипта) и формой «Установить состояние» в
  админ-панели (показать ошибку до отправки).
  """

  @type schema :: nil | String.t() | %{optional(String.t()) => schema}

  @spec validate(schema(), doc :: term()) :: :ok | {:error, String.t()}
  def validate(nil, _doc), do: :ok

  def validate(schema, doc), do: check(schema, doc, "$")

  @doc """
  Валидация корневого документа при наличии карт схем `%{state_key | nil => schema}`.
  Есть схема корня — проверяется весь документ; иначе — каждая ветка документа,
  для которой объявлена схема (ветки без схемы не трогаем).
  """
  @spec validate_root(%{optional(term()) => schema()}, doc :: term()) ::
          :ok | {:error, String.t()}
  def validate_root(schemas, _doc) when schemas == %{} or is_nil(schemas), do: :ok

  def validate_root(schemas, doc) when is_map(doc) do
    case Map.get(schemas, nil) do
      nil ->
        Enum.find_value(doc, :ok, fn {key, subdoc} ->
          case Map.fetch(schemas, key) do
            {:ok, schema} ->
              case check(schema, subdoc, "$." <> to_string(key)) do
                :ok -> nil
                {:error, _} = err -> err
              end

            :error ->
              nil
          end
        end)

      schema ->
        validate(schema, doc)
    end
  end

  def validate_root(schemas, doc) do
    case Map.get(schemas, nil) do
      nil -> :ok
      schema -> validate(schema, doc)
    end
  end

  # -------------------------------------------------------------------------

  # незаданное поле: null проходит против любого дескриптора
  defp check(_schema, nil, _path), do: :ok

  defp check("number", v, _path) when is_number(v), do: :ok
  defp check("number", v, path), do: {:error, "#{path}: ожидался number, получен #{kind(v)}"}

  defp check("string", v, _path) when is_binary(v), do: :ok
  defp check("string", v, path), do: {:error, "#{path}: ожидалась string, получен #{kind(v)}"}

  defp check("boolean", v, _path) when is_boolean(v), do: :ok
  defp check("boolean", v, path), do: {:error, "#{path}: ожидался boolean, получен #{kind(v)}"}

  defp check("any", _v, _path), do: :ok
  defp check(nil, _v, _path), do: :ok

  defp check(%{"map" => inner}, doc, path) when is_map(doc) do
    Enum.find_value(doc, :ok, fn {key, value} ->
      case check(inner, value, "#{path}.#{key}") do
        :ok -> nil
        {:error, _} = err -> err
      end
    end)
  end

  defp check(%{"map" => _inner}, doc, path),
    do: {:error, "#{path}: ожидался объект, получен #{kind(doc)}"}

  defp check(%{"list" => inner}, doc, path) when is_list(doc) do
    doc
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {value, i} ->
      case check(inner, value, "#{path}[#{i}]") do
        :ok -> nil
        {:error, _} = err -> err
      end
    end)
  end

  defp check(%{"list" => _inner}, doc, path),
    do: {:error, "#{path}: ожидался массив, получен #{kind(doc)}"}

  # структура: известные поля проверяем, неизвестные — ошибка
  defp check(schema, doc, path) when is_map(schema) and is_map(doc) do
    Enum.find_value(doc, :ok, fn {key, value} ->
      case Map.fetch(schema, key) do
        {:ok, sub} ->
          case check(sub, value, "#{path}.#{key}") do
            :ok -> nil
            {:error, _} = err -> err
          end

        :error ->
          {:error, "#{path}.#{key}: поле не объявлено в схеме"}
      end
    end)
  end

  defp check(schema, doc, path) when is_map(schema),
    do: {:error, "#{path}: ожидался объект, получен #{kind(doc)}"}

  defp check(schema, _doc, path),
    do: {:error, "#{path}: неизвестный дескриптор схемы #{inspect(schema)}"}

  defp kind(nil), do: "null"
  defp kind(v) when is_boolean(v), do: "boolean"
  defp kind(v) when is_number(v), do: "number"
  defp kind(v) when is_binary(v), do: "string"
  defp kind(v) when is_list(v), do: "array"
  defp kind(v) when is_map(v), do: "object"
  defp kind(v), do: inspect(v)
end
