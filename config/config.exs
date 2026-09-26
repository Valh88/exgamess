# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.

# General application configuration
import Config

# ----------------------------------------------------------------------------
# ex_games — ядро фреймворка (комнаты, матчмейкинг, presence, чат)
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# ex_games_account — аккаунты, роли, токены (Ecto + SQLite)
# ----------------------------------------------------------------------------
config :ex_games_account, ecto_repos: [ExGames.Account.Repo]

# Абсолютный путь от config/ — umbrella запускает тесты каждой аппки со своим
# cwd, относительные пути давали бы «две разные базы».
config :ex_games_account, ExGames.Account.Repo,
  database:
    Path.expand(
      "../apps/ex_games_account/priv/repo/#{config_env()}.sqlite3",
      __DIR__
    ),
  # WAL + immediate-транзакции: меньше гонок «database is locked».
  journal_mode: :wal,
  default_transaction_mode: :immediate,
  pool_size: 5

config :ex_games_account, :token,
  secret_key_base: "dev-only-insecure-secret-key-base-change-me",
  salt: "ex games account token v1",
  ttl_seconds: 86_400

config :ex_games_account, :seeds,
  admin_username: System.get_env("EX_GAMES_ADMIN_USERNAME", "admin"),
  admin_password: System.get_env("EX_GAMES_ADMIN_PASSWORD", "admin123123")

# ----------------------------------------------------------------------------
# ex_games_web — Phoenix (Bandit): REST + WebSocket + LiveView (буд. админка)
# ----------------------------------------------------------------------------
config :ex_games_web, ecto_repos: [ExGamesWeb.Repo]

config :ex_games_web,
  namespace: ExGamesWebWeb,
  generators: [timestamp_type: :utc_datetime]

config :ex_games_web, ExGamesWebWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ExGamesWebWeb.ErrorHTML, json: ExGamesWebWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ExGamesWeb.PubSub,
  live_view: [signing_salt: "62UW+4B3"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ex_games_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/ex_games_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  ex_games_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/ex_games_web", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Sample configuration:
#
#     config :logger, :default_handler,
#       level: :info
#
#     config :logger, :default_formatter,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#
