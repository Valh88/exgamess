defmodule ExGamesWebWeb.SavesController do
  @moduledoc """
  Облачные сохранения игрока. Payload — непрозрачный JSON-объект: сервер
  не знает его форму, хранит как есть и отдаёт целиком.

      PUT    /api/saves/:key   {"payload": {...}}   — сохранить/перезаписать
      GET    /api/saves/:key                        — {"key": ..., "payload": {...}}
      GET    /api/saves                             — список слотов (без payload)
      DELETE /api/saves/:key                        — 204

  Размер payload ограничен (`config :ex_games_web, :save_max_bytes`,
  по умолчанию 256 KiB закодированного JSON) — 413 при превышении.
  """

  use ExGamesWebWeb, :controller

  action_fallback ExGamesWebWeb.FallbackController

  def update(conn, %{"key" => key, "payload" => payload}) when is_map(payload) do
    with :ok <- check_size(payload),
         {:ok, save} <-
           ExGames.Account.save_data(conn.assigns.current_user.id, key, payload) do
      json(conn, save_wire(save))
    end
  end

  def update(_conn, %{"key" => _key}) do
    {:error, "payload must be a JSON object"}
  end

  def show(conn, %{"key" => key}) do
    with {:ok, payload} <- ExGames.Account.get_save(conn.assigns.current_user.id, key) do
      json(conn, %{"key" => key, "payload" => payload})
    end
  end

  def index(conn, _params) do
    saves =
      Enum.map(ExGames.Account.list_saves(conn.assigns.current_user.id), fn slot ->
        %{"key" => slot.key, "updated_at" => NaiveDateTime.to_iso8601(slot.updated_at)}
      end)

    json(conn, %{"saves" => saves})
  end

  def delete(conn, %{"key" => key}) do
    with :ok <- ExGames.Account.delete_save(conn.assigns.current_user.id, key) do
      send_resp(conn, 204, "")
    end
  end

  defp check_size(payload) do
    if byte_size(Jason.encode!(payload)) > max_bytes(),
      do: {:error, :save_too_large},
      else: :ok
  end

  defp max_bytes, do: Application.get_env(:ex_games_web, :save_max_bytes, 256 * 1024)

  defp save_wire(save) do
    %{
      "key" => save.key,
      "payload" => save.payload,
      "updated_at" => save.updated_at && NaiveDateTime.to_iso8601(save.updated_at)
    }
  end
end
