{:ok, _} = Application.ensure_all_started(:ex_games_account)
{:ok, _} = Application.ensure_all_started(:ex_games)
ExUnit.configure(exclude: [native: true])
ExUnit.start()
