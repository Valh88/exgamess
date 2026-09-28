defmodule ExGamesWebWeb.Plugs.CORS do
  @moduledoc """
  CORS для браузерных клиентов (Haxe→JS и любые веб-клиенты).

  В dev/testing разрешаем все origin (`*`); в проде задаётся конфигом:

      config :ex_games_web, :cors_origin, "https://game.example.com"
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = Application.get_env(:ex_games_web, :cors_origin, "*")

    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "authorization, content-type")
    |> put_resp_header("access-control-max-age", "86400")
    |> handle_preflight()
  end

  defp handle_preflight(%{method: "OPTIONS"} = conn) do
    conn
    |> send_resp(204, "")
    |> halt()
  end

  defp handle_preflight(conn), do: conn
end
