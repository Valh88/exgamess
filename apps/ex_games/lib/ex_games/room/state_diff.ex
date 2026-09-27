defmodule ExGames.Room.StateDiff do
  @moduledoc """
  Структурный дифф wire-состояния комнаты для дельта-синхронизации
  (кадр `ROOM_STATE_PATCH`, opcode 15 — см. `doc/PROTOCOL.md`).

  Формат операции:

    * `%{"p" => path, "v" => value}` — установить/заменить значение по пути
      (`path` — список строковых ключей, `[]` — корень состояния);
    * `%{"p" => path, "d" => true}` — удалить ключ по пути.

  Списки и прочие не-map значения диффируются атомарно: любое отличие —
  замена целиком по пути (внутрь массивов дифф не заходит — без
  index-shift). Операции — «присваивание значений»: их можно безопасно
  применять к любому более новому срезу состояния (идемпотентно).
  """

  @doc "Дифф двух wire-состояний: список операций. `[]` — состояния равны."
  @spec diff(term(), term()) :: [map()]
  def diff(old, new), do: walk(old, new, [])

  @doc "Применяет операции к состоянию (симметрично `diff/2`)."
  @spec apply(term(), [map()]) :: term()
  def apply(state, ops) when is_list(ops) do
    Enum.reduce(ops, state, fn
      %{"p" => path, "d" => true}, acc -> del_at(acc, path)
      %{"p" => path, "v" => value}, acc -> set_at(acc, path, value)
    end)
  end

  # map ↔ map: рекурсия по ключам
  defp walk(old, new, path) when is_map(old) and is_map(new) do
    changed =
      Enum.flat_map(new, fn {k, v} ->
        case Map.fetch(old, k) do
          :error ->
            [set_op([k | path], v)]

          {:ok, old_v} ->
            cond do
              is_map(old_v) and is_map(v) -> walk(old_v, v, [k | path])
              old_v == v -> []
              true -> [set_op([k | path], v)]
            end
        end
      end)

    removed =
      for k <- Map.keys(old), not Map.has_key?(new, k) do
        del_op([k | path])
      end

    changed ++ removed
  end

  # хотя бы одна сторона не map: корневая замена по текущему пути
  defp walk(old, new, path) do
    if old == new, do: [], else: [set_op(path, new)]
  end

  defp set_op(path, value), do: %{"p" => Enum.reverse(path), "v" => value}
  defp del_op(path), do: %{"p" => Enum.reverse(path), "d" => true}

  # -------------------------------------------------------------------------
  # apply
  # -------------------------------------------------------------------------

  defp set_at(state, [], value), do: value

  defp set_at(state, [k | rest], value) do
    base = if is_map(state), do: state, else: %{}
    child = map_or_new(Map.get(base, k))
    Map.put(base, k, set_at(child, rest, value))
  end

  defp del_at(_state, []), do: nil

  defp del_at(state, [k]) when is_map(state), do: Map.delete(state, k)

  defp del_at(state, [k | rest]) when is_map(state) do
    child = map_or_new(Map.get(state, k))
    Map.put(state, k, del_at(child, rest))
  end

  defp del_at(state, _path), do: state

  defp map_or_new(v) when is_map(v), do: v
  defp map_or_new(_), do: %{}
end
