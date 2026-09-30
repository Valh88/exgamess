defmodule ExGamesWebWeb.FallbackController do
  @moduledoc """
  Трансляция `{:error, ...}` из контроллеров в JSON-ответы с корректными
  статусами.
  """

  use ExGamesWebWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    {:ok, errors} = Jason.encode(ExGames.Account.changeset_errors(changeset))

    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ExGamesWebWeb.ErrorJSON)
    |> render(:errors, errors: errors)
  end

  def call(conn, {:error, errors}) when is_map(errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end

  def call(conn, {:error, reason}) when is_atom(reason) do
    {status, code} = error_for(reason)

    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: Atom.to_string(reason)}})
  end

  def call(conn, {:error, reason}) when is_binary(reason) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: 400, message: reason}})
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: %{code: 500, message: inspect(reason)}})
  end

  # Коды ошибок согласованы с протоколом.
  defp error_for(:not_found), do: {:not_found, 404}
  defp error_for(:save_too_large), do: {:request_entity_too_large, 413}
  defp error_for(:unknown_user), do: {:not_found, 404}
  defp error_for(:unknown_room_type), do: {:not_found, 520}
  defp error_for(:no_room), do: {:not_found, 521}

  # нода сливает трафик (graceful shutdown) — новых игроков не берём
  defp error_for(:draining), do: {:service_unavailable, 503}
  defp error_for(:unknown_room), do: {:not_found, 522}
  defp error_for(:no_reservation), do: {:not_found, 522}
  defp error_for(:invalid_token), do: {:not_found, 522}
  defp error_for(:bad_credentials), do: {:unauthorized, 401}
  defp error_for(:banned), do: {:forbidden, 403}
  defp error_for(:locked), do: {:locked, 423}
  defp error_for(:full), do: {:forbidden, 523}
  defp error_for(:auth_failed), do: {:unauthorized, 525}
  defp error_for(_reason), do: {:internal_server_error, 526}
end
