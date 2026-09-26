defmodule ExGames.Account do
  @moduledoc """
  Аккаунты: регистрация, вход, токены, роли (RBAC), баны.

  Основной API:

      {:ok, user} = Account.register(%{"username" => "ann", "password" => "secret1"})
      {:ok, token} = Account.login("ann", "secret1")
      {:ok, user}  = Account.authenticate(token)
      Account.has_role?(user, :admin)
  """

  import Ecto.Query

  alias ExGames.Account.Repo
  alias ExGames.Account.Role
  alias ExGames.Account.Token
  alias ExGames.Account.User

  @typedoc "Результат операции аккаунта."
  @type result(type) :: {:ok, type} | {:error, term()}

  @type t :: User.t()

  # -------------------------------------------------------------------------
  # Регистрация / вход
  # -------------------------------------------------------------------------

  @doc "Регистрирует пользователя (роль `player` выдаётся автоматически)."
  @spec register(map()) :: result(User.t())
  def register(attrs) when is_map(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        {:ok, _role, _} = grant_role(user, :player)
        {:ok, with_roles(user)}
      {:error, changeset} ->
        {:error, changeset_errors(changeset)}
    end
  end

  @doc "Вход по логину/паролю; возвращает подписанный токен."
  @spec login(String.t(), String.t()) :: result({:token, String.t(), User.t()})
  def login(username, password) when is_binary(username) and is_binary(password) do
    user = Repo.one(from u in User, where: u.username == ^username, preload: [:roles])

    with {:ok, user} <- check_password(user, password),
         :ok <- check_not_banned(user) do
      case Token.sign(user.id) do
        {:ok, token} -> {:ok, {:token, token, user}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Проверяет токен и возвращает пользователя (или :banned)."
  @spec authenticate(String.t()) :: result(User.t())
  def authenticate(token) when is_binary(token) do
    with {:ok, user_id} <- Token.verify(token),
         {:ok, user} <- fetch_user_by_id(user_id),
         :ok <- check_not_banned(user) do
      {:ok, with_roles(user)}
    end
  end

  @doc "Профиль по имени."
  @spec fetch_user(String.t()) :: result(User.t())
  def fetch_user(username) do
    case Repo.one(from u in User, where: u.username == ^username, preload: [:roles]) do
      nil -> {:error, :unknown_user}
      user -> {:ok, user}
    end
  end

  defp fetch_user_by_id(id) do
    case Repo.one(from u in User, where: u.id == ^id, preload: [:roles]) do
      nil -> {:error, :unknown_user}
      user -> {:ok, user}
    end
  end

  # Timing-safe проверка пароля: для несуществующего пользователя тоже
  # считаем хэш, чтобы не раскрывать перебор логинов.
  defp check_password(%User{password_hash: hash} = user, password) when is_binary(hash) do
    if Pbkdf2.verify_pass(password, hash), do: {:ok, user}, else: {:error, :bad_credentials}
  end

  defp check_password(_user, _password) do
    Pbkdf2.no_user_verify()
    {:error, :bad_credentials}
  end

  # -------------------------------------------------------------------------
  # Роли (RBAC)
  # -------------------------------------------------------------------------

  @doc "Есть ли у пользователя роль (по atom-имени)."
  @spec has_role?(User.t() | nil, atom() | String.t()) :: boolean()
  def has_role?(nil, _role), do: false

  def has_role?(%User{roles: roles}, role) when is_atom(role) do
    Enum.any?(roles, &(&1.name == Atom.to_string(role)))
  end

  def has_role?(%User{roles: roles}, role) when is_binary(role) do
    Enum.any?(roles, &(&1.name == role))
  end

  @doc "Выдаёт роль пользователю; роль создаётся, если ещё не существует."
  @spec grant_role(User.t(), atom() | String.t()) :: result({Role.t(), non_neg_integer()})
  def grant_role(user, role_name) when is_atom(role_name),
    do: grant_role(user, Atom.to_string(role_name))

  def grant_role(user, role_name) when is_binary(role_name) do
    {:ok, role} = ensure_role(role_name)

    {count, nil} =
      Repo.insert_all("users_roles", [%{user_id: user.id, role_id: role.id}],
        on_conflict: :nothing
      )

    {:ok, role, count}
  end

  @doc "Забирает роль у пользователя."
  @spec revoke_role(User.t(), atom() | String.t()) :: :ok
  def revoke_role(user, role_name) when is_atom(role_name),
    do: revoke_role(user, Atom.to_string(role_name))

  def revoke_role(user, role_name) when is_binary(role_name) do
    Repo.query!("DELETE FROM users_roles WHERE user_id = ? AND role_id = (SELECT id FROM roles WHERE name = ?)", [
      user.id,
      role_name
    ])

    :ok
  end

  defp ensure_role(name) do
    case Repo.one(from r in Role, where: r.name == ^name) do
      nil -> Repo.insert(Role.changeset(%Role{}, %{name: name}))
      role -> {:ok, role}
    end
  end

  # -------------------------------------------------------------------------
  # Баны
  # -------------------------------------------------------------------------

  @doc "Банит пользователя (moderator action)."
  @spec ban(User.t(), String.t()) :: result(User.t())
  def ban(%User{} = user, reason) do
    user
    |> User.ban_changeset(%{ban_reason: reason})
    |> Repo.update()
    |> case do
      {:ok, user} -> {:ok, with_roles(user)}
      {:error, changeset} -> {:error, changeset_errors(changeset)}
    end
  end

  @doc "Снимает бан."
  @spec unban(User.t()) :: result(User.t())
  def unban(%User{} = user) do
    user
    |> Ecto.Changeset.change(banned_at: nil, ban_reason: nil)
    |> Repo.update()
    |> case do
      {:ok, user} -> {:ok, with_roles(user)}
      {:error, changeset} -> {:error, changeset_errors(changeset)}
    end
  end

  # -------------------------------------------------------------------------
  # Вспомогательное
  # -------------------------------------------------------------------------

  @doc "Пользователь с предзагруженными ролями."
  @spec with_roles(User.t()) :: User.t()
  def with_roles(%User{} = user) do
    if Ecto.assoc_loaded?(user.roles) do
      user
    else
      Repo.preload(user, :roles)
    end
  end

  @doc "Строковые ошибки changeset (для JSON-ответов)."
  @spec changeset_errors(Ecto.Changeset.t()) :: %{String.t() => [String.t()]}
  def changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _match, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp check_not_banned(%User{banned_at: nil}), do: :ok
  defp check_not_banned(%User{}), do: {:error, :banned}
end
