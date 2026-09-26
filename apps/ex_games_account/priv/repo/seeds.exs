# Сиды аккаунтов: администратор из конфига (:ex_games_account, :seeds).
alias ExGames.Account

seeds = Application.get_env(:ex_games_account, :seeds, [])
username = Keyword.fetch!(seeds, :admin_username)
password = Keyword.fetch!(seeds, :admin_password)

case Account.fetch_user(username) do
  {:ok, user} ->
    IO.puts("[seeds] admin '#{username}' уже существует (id=#{user.id})")

  {:error, :unknown_user} ->
    case Account.register(%{"username" => username, "password" => password}) do
      {:ok, user} ->
        {:ok, _role, _} = Account.grant_role(user, :moderator)
        {:ok, _role, _} = Account.grant_role(user, :admin)
        IO.puts("[seeds] создан admin '#{username}' с ролями player+moderator+admin")

      {:error, errors} ->
        IO.puts("[seeds] не удалось создать admin: #{inspect(errors)}")
    end
end
