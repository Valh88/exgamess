defmodule ExGamesWebWeb.Plugs.Auth do
  @moduledoc """
  Аутентификация Bearer-токеном: `Authorization: Bearer <token>`.

  Успех — кладёт `:current_user` в conn. Отсутствие/невалидность токена
  не прерывает запрос (за требование авторизации отвечает `RequireAuth`),
  но неаутентифицированный пользователь недоступен.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- ExGames.Account.authenticate(token) do
      assign(conn, :current_user, user)
    else
      _ -> conn
    end
  end
end

defmodule ExGamesWebWeb.Plugs.RequireAuth do
  @moduledoc "Прерывает запрос 401, если нет `:current_user`."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_status(401)
      |> Phoenix.Controller.put_view(json: ExGamesWebWeb.ErrorJSON)
      |> Phoenix.Controller.render(:"401")
      |> halt()
    end
  end
end

defmodule ExGamesWebWeb.Plugs.RequireRole do
  @moduledoc """
  Требует у текущего пользователя роль: `plug RequireRole, :admin`.
  Без аутентификации — 401, с ней, но без роли — 403.
  """

  import Plug.Conn

  def init(role), do: role

  def call(conn, role) do
    user = conn.assigns[:current_user]

    cond do
      is_nil(user) ->
        conn
        |> put_status(401)
        |> Phoenix.Controller.put_view(json: ExGamesWebWeb.ErrorJSON)
        |> Phoenix.Controller.render(:"401")
        |> halt()

      ExGames.Account.has_role?(user, role) ->
        conn

      true ->
        conn
        |> put_status(403)
        |> Phoenix.Controller.put_view(json: ExGamesWebWeb.ErrorJSON)
        |> Phoenix.Controller.render(:"403")
        |> halt()
    end
  end
end
