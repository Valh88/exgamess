defmodule ExGamesWebWeb.GatewayWsController do
  @moduledoc """
  Апгрейд HTTP → WebSocket мультиплексирования:

      GET /ws

  Комната не в URL: клиент входит в комнаты кадрами `room_enter`
  (бронь `session_id` либо `reconnection_token`) — см.
  `ExGamesWebWeb.GatewaySocket` и doc/PROTOCOL.md.
  """

  use ExGamesWebWeb, :controller

  def upgrade(conn, _params) do
    WebSockAdapter.upgrade(
      conn,
      ExGamesWebWeb.GatewaySocket,
      %{},
      # timeout — простой без ДАННЫХ ОТ КЛИЕНТА (keepalive-PING обязаны быть
      # чаще); опции идут напрямую в ThousandIsland
      timeout: 60_000,
      idle_timeout: :infinity
    )
  end
end
