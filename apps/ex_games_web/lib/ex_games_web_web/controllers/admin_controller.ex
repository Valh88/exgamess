defmodule ExGamesWebWeb.AdminController do
  @moduledoc "REST-админка: роли и баны (требует роль `admin`)."

  use ExGamesWebWeb, :controller

  import Ecto.Query

  action_fallback ExGamesWebWeb.FallbackController

  def list_users(conn, _params) do
    users =
      ExGames.Account.Repo.all(ExGames.Account.User)
      |> ExGames.Account.Repo.preload(:roles)
      |> Enum.map(&ExGames.Account.User.to_wire/1)

    json(conn, %{"users" => users})
  end

  def show_user(conn, %{"id" => id}) do
    with {:ok, user} <- fetch_user(id) do
      json(conn, %{"user" => ExGames.Account.User.to_wire(user)})
    end
  end

  def grant_role(conn, %{"id" => id, "role" => role}) do
    with {:ok, user} <- fetch_user(id),
         {:ok, _role, _count} <- ExGames.Account.grant_role(user, role) do
      {:ok, user} = ExGames.Account.fetch_user(user.username)
      json(conn, %{"user" => ExGames.Account.User.to_wire(user)})
    end
  end

  def revoke_role(conn, %{"id" => id, "role" => role}) do
    with {:ok, user} <- fetch_user(id) do
      :ok = ExGames.Account.revoke_role(user, role)
      {:ok, user} = ExGames.Account.fetch_user(user.username)
      json(conn, %{"user" => ExGames.Account.User.to_wire(user)})
    end
  end

  def ban(conn, %{"id" => id} = params) do
    with {:ok, user} <- fetch_user(id),
         {:ok, banned} <- ExGames.Account.ban(user, params["reason"] || "unspecified") do
      json(conn, %{"user" => ExGames.Account.User.to_wire(banned)})
    end
  end

  def unban(conn, %{"id" => id}) do
    with {:ok, user} <- fetch_user(id),
         {:ok, unbanned} <- ExGames.Account.unban(user) do
      json(conn, %{"user" => ExGames.Account.User.to_wire(unbanned)})
    end
  end

  defp fetch_user(id) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case ExGames.Account.Repo.one(
               from u in ExGames.Account.User,
                 where: u.id == ^int_id,
                 preload: [:roles]
             ) do
          nil -> {:error, :unknown_user}
          user -> {:ok, user}
        end

      _ ->
        {:error, "invalid user id"}
    end
  end
end
