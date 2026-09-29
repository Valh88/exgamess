defmodule ExGamesWebWeb.AdminController do
  @moduledoc "REST-админка: роли и баны (требует роль `admin`)."

  use ExGamesWebWeb, :controller

  action_fallback ExGamesWebWeb.FallbackController

  def list_users(conn, params) do
    banned =
      case params["banned"] do
        "true" -> true
        "false" -> false
        _ -> nil
      end

    listing =
      ExGames.Account.list_users(
        search: params["search"],
        role: params["role"],
        banned: banned,
        page_size: 100
      )

    users = Enum.map(listing.entries, &ExGames.Account.User.to_wire/1)
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
      {int_id, ""} -> ExGames.Account.fetch_user_by_id(int_id)
      _ -> {:error, "invalid user id"}
    end
  end
end
