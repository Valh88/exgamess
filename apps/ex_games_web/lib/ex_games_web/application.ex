defmodule ExGamesWeb.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ExGamesWebWeb.Telemetry,
      ExGamesWeb.Repo,
      {DNSCluster, query: Application.get_env(:ex_games_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ExGamesWeb.PubSub},
      # Start a worker by calling: ExGamesWeb.Worker.start_link(arg)
      # {ExGamesWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      ExGamesWebWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ExGamesWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ExGamesWebWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @impl true
  # Плановая остановка: опустошение ноды ДО гашения supervision tree —
  # матчмейкер закрывается, живые комнаты получают 4001 «server shutdown».
  # В тестах drain не используется (config :ex_games_web, :prep_stop_drain, false).
  def prep_stop(state) do
    if Application.get_env(:ex_games_web, :prep_stop_drain, true) do
      ExGames.Runtime.Drain.drain()
    end

    state
  end
end
