defmodule ExGames.Account.Token do
  @moduledoc """
  Подпись/проверка auth-токенов.

  Реализация по умолчанию — HMAC (`Plug.Crypto.sign/verify`), ключ из
  конфига. Для смены механизма (например, настоящий JWT) достаточно
  определить свой модуль с этим контрактом и указать его в конфиге:

      config :ex_games_account, :token, impl: MyApp.JWT
  """

  @callback sign(user_id :: pos_integer()) :: {:ok, String.t()} | {:error, term()}
  @callback verify(token :: String.t()) :: {:ok, user_id :: pos_integer()} | {:error, term()}

  @impl_module Application.compile_env(:ex_games_account, [:token, :impl]) ||
                 ExGames.Account.Token.HMAC

  @doc "Подписывает токен для пользователя."
  @spec sign(pos_integer()) :: {:ok, String.t()} | {:error, term()}
  defdelegate sign(user_id), to: @impl_module

  @doc "Проверяет токен, возвращает user_id."
  @spec verify(String.t()) :: {:ok, pos_integer()} | {:error, term()}
  defdelegate verify(token), to: @impl_module
end

defmodule ExGames.Account.Token.HMAC do
  @moduledoc """
  HMAC-токены на `Plug.Crypto`: `user_id | expiry | nonce`, подписанные
  secret_key_base + salt из конфига. Токены — читаемые ASCII-строки,
  удобные для передачи в JSON и заголовке Authorization.
  """

  @behaviour ExGames.Account.Token

  @impl true
  def sign(user_id) do
    config = token_config()

    Plug.Crypto.sign(
      config.secret_key_base,
      config.salt,
      %{uid: user_id},
      max_age: config.ttl_seconds
    )
    |> then(&{:ok, &1})
  rescue
    e -> {:error, e}
  end

  @impl true
  def verify(token) do
    config = token_config()

    case Plug.Crypto.verify(config.secret_key_base, config.salt, token, max_age: config.ttl_seconds) do
      {:ok, %{uid: uid}} when is_integer(uid) -> {:ok, uid}
      {:ok, _other} -> {:error, :invalid_token}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp token_config do
    config = Application.get_env(:ex_games_account, :token, [])

    %{
      secret_key_base: Keyword.fetch!(config, :secret_key_base),
      salt: Keyword.fetch!(config, :salt),
      ttl_seconds: Keyword.get(config, :ttl_seconds, 86_400)
    }
  end
end
