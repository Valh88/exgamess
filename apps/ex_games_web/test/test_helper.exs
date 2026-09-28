{:ok, _} = Application.ensure_all_started(:ex_games_account)
{:ok, _} = Application.ensure_all_started(:ex_games)
{:ok, _} = Application.ensure_all_started(:ex_games_web)
ExUnit.start()
