defmodule ExGamesWebWeb.PageController do
  use ExGamesWebWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
