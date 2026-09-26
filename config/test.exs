import Config

# ----------------------------------------------------------------------------
# SQLite: аккаунты — SQL Sandbox (изоляция тестов транзакциями)
# ----------------------------------------------------------------------------
config :ex_games_account, ExGames.Account.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# SQLite в тестах: SQL Sandbox работает и с ecto_sqlite3.
# MIX_TEST_PARTITION позволяет распараллелить прогон в CI.
config :ex_games_web, ExGamesWeb.Repo,
  database:
    Path.expand(
      "../apps/ex_games_web/priv/db/test#{System.get_env("MIX_TEST_PARTITION")}.db",
      __DIR__
    ),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Интеграционные тесты WS-транспорта ходят по настоящему HTTP/WS.
config :ex_games_web, ExGamesWebWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4045],
  secret_key_base: "K0bL9RjIcLLKqf6jwlAj2YUSZJGPrvU5NhRGXDgIxuyZJl/RZDYeY4K6ByBou6Yh",
  server: true

# In test we don't send emails
config :ex_games_web, ExGamesWeb.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
