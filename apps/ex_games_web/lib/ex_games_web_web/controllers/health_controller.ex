defmodule ExGamesWebWeb.HealthController do
  @moduledoc """
  Пробы для оркестратора/балансировщика (без auth):

    * `GET /healthz` — liveness: процесс отвечает (всегда 200);
      нет ответа — нода зависла, её нужно перезапускать.
    * `GET /readyz` — readiness: принимать ли новых игроков
      (503 `{"status":"draining"}` при плановом опустошении —
      см. `ExGames.Runtime.Drain`).
  """

  use ExGamesWebWeb, :controller

  def healthz(conn, _params), do: json(conn, %{status: "ok"})

  def readyz(conn, _params) do
    if ExGames.Runtime.Drain.draining?() do
      conn
      |> put_status(:service_unavailable)
      |> json(%{status: "draining"})
    else
      json(conn, %{status: "ok"})
    end
  end
end
