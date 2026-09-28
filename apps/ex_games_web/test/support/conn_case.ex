defmodule ExGamesWebWeb.ConnCase do
  @moduledoc """
  Тестовый кейс веб-слоя: sandbox аккаунт-репозитория (для auth-плагов),
  подставной транспортный pid и helpers для регистрации/логина.
  """

  use ExUnit.CaseTemplate

  import Phoenix.ConnTest
  @endpoint ExGamesWebWeb.Endpoint

  using do
    quote do
      @endpoint ExGamesWebWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import ExGamesWebWeb.ConnCase
    end
  end

  setup tags do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(ExGames.Account.Repo, shared: not tags[:async])

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Регистрирует пользователя и возвращает ответ с token и user.
  """
  def register_user!(conn, username \\ nil, password \\ "secret123") do
    username = username || "user_#{System.unique_integer([:positive])}"

    conn
    |> post("/api/auth/register", %{"username" => username, "password" => password})
    |> json_response(201)
  end

  @doc "Conn с Bearer-заголовком."
  def auth_conn(conn, token) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end
end
