defmodule ExGamesWebWeb.Router do
  use ExGamesWebWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ExGamesWebWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug ExGamesWebWeb.Plugs.Auth
  end

  pipeline :require_auth do
    plug ExGamesWebWeb.Plugs.RequireAuth
  end

  pipeline :require_admin do
    plug ExGamesWebWeb.Plugs.RequireRole, :admin
  end

  # Публичный JSON: регистрация и вход.
  scope "/api/auth", ExGamesWebWeb do
    pipe_through :api

    post "/register", AuthController, :register
    post "/login", AuthController, :login
  end

  # Пробы оркестратора/балансировщика (без auth): liveness и readiness.
  scope "/", ExGamesWebWeb do
    pipe_through :api

    get "/healthz", HealthController, :healthz
    get "/readyz", HealthController, :readyz
  end

  # Игровой JSON API: только с Bearer-токеном.
  scope "/api", ExGamesWebWeb do
    pipe_through [:api, :require_auth]

    get "/me", AuthController, :me

    # частные маршруты — до обобщённого /matchmake/:method/:room_name
    post "/matchmake/reconnect/:room_id", MatchmakeController, :reconnect
    post "/matchmake/join_by_id/:room_id", MatchmakeController, :join_by_id
    post "/matchmake/:method/:room_name", MatchmakeController, :matchmake
    get "/rooms", RoomsController, :index
  end

  # Админ-REST: требует роль admin (будущая LiveView-админка переиспользует).
  scope "/api/admin", ExGamesWebWeb do
    pipe_through [:api, :require_auth, :require_admin]

    get "/users", AdminController, :list_users
    get "/users/:id", AdminController, :show_user
    post "/users/:id/roles", AdminController, :grant_role
    delete "/users/:id/roles/:role", AdminController, :revoke_role
    post "/users/:id/ban", AdminController, :ban
    post "/users/:id/unban", AdminController, :unban
  end

  scope "/", ExGamesWebWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", ExGamesWebWeb do
    # WebSocket-апгрейд (не JSON): идентификация по seat reservation.
    get "/ws/:room_id", WsController, :upgrade
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:ex_games_web, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ExGamesWebWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
