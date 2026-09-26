{:ok, _} = Application.ensure_all_started(:ex_games)

# Нативные тесты (Port-адаптер, spawn внешних процессов) — только явно:
# mix test --include native
ExUnit.configure(exclude: [native: true])

ExUnit.start()
