defmodule ExGamesWebWeb.WsController do
  @moduledoc """
  Апгрейд HTTP → WebSocket для подключения к комнате:

      GET /ws/:room_id?sessionId=:session_id
      GET /ws/:room_id?sessionId=:session_id&reconnectionToken=:token

  Во втором варианте (reconnect-флоу, шаг 2) сокет переподключает транспорт
  к сессии по reconnection-токену вместо новой брони.

  Валидирует наличие session_id и апгрейдит соединение в
  `ExGamesWebWeb.RoomSocket`, который привязывает сокет к месту в комнате.
  """

  use ExGamesWebWeb, :controller

  def upgrade(conn, %{"room_id" => room_id}) do
    case conn.query_params["sessionId"] do
      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: 522, message: "sessionId query param required"}})

      session_id when is_binary(session_id) ->
        mount = %{room_id: room_id, session_id: session_id}

        mount =
          case conn.query_params["reconnectionToken"] do
            token when is_binary(token) -> Map.put(mount, :reconnection_token, token)
            _ -> mount
          end

        WebSockAdapter.upgrade(
          conn,
          ExGamesWebWeb.RoomSocket,
          mount,
          # timeout — простой без ДАННЫХ ОТ КЛИЕНТА, после которого Bandit
          # закрывает сокет (клиентские keepalive-PING обязаны быть чаще);
          # для Bandit-адаптера опции идут напрямую в ThousandIsland
          timeout: 60_000,
          idle_timeout: :infinity
        )
    end
  end
end
