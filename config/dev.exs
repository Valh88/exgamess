import Config

# SQLite: путь абсолютный от config/ (cwd umbrella-приложений различается).
config :ex_games_web, ExGamesWeb.Repo,
  database: Path.expand("../apps/ex_games_web/priv/db/dev.db", __DIR__),
  default_transaction_mode: :immediate,
  pool_size: 10

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :ex_games_web, ExGamesWebWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}],
  # https/wss-листенер на самоподписанном dev-сертификате (`mix phx.gen.cert`
  # в apps/ex_games_web). Браузер один раз принимает сертификат, открыв
  # https://localhost:4001; нативные клиенты (HL) для self-signed отключают
  # проверку — см. «TLS» в README.
  https: [
    ip: {127, 0, 0, 1},
    port: 4001,
    # :compatible = TLS 1.2 + 1.3 (:strong — только 1.3, HL/mbedtls его не умеет)
    cipher_suite: :compatible,
    certfile: Path.expand("../apps/ex_games_web/priv/cert/selfsigned.pem", __DIR__),
    keyfile: Path.expand("../apps/ex_games_web/priv/cert/selfsigned_key.pem", __DIR__)
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "ic0dVvqWl1c5hA+mYNIZLZtGWhEhJyhribS/mriyWOqzcNCLFfIHl1KFQsEoInxf",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:ex_games_web, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:ex_games_web, ~w(--watch)]}
  ]

# Enable dev routes for dashboard and mailbox
config :ex_games_web, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false
# 
# ВРЕМЕННО (тест браузерного демо со статик-сервера :5500) — удалить после теста:
config :ex_games_web, :cors_origin, "http://127.0.0.1:5500"
