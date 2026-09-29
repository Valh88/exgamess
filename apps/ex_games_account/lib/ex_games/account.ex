defmodule ExGames.Account do
  @moduledoc """
  Аккаунты: регистрация, вход, токены, роли (RBAC), баны, рейтинги (Elo).

  Основной API:

      {:ok, user} = Account.register(%{"username" => "ann", "password" => "secret1"})
      {:ok, token} = Account.login("ann", "secret1")
      {:ok, user}  = Account.authenticate(token)
      Account.has_role?(user, :admin)
      Account.record_match("arena", %{1 => :win, 2 => :loss})
  """

  import Ecto.Query

  alias ExGames.Account.Repo
  alias ExGames.Account.Role
  alias ExGames.Account.Token
  alias ExGames.Account.User
  alias ExGames.Account.Rating
  alias ExGames.Account.MatchResult
  alias ExGames.Account.Save

  @k_factor 32

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
    user = Repo.one(from(u in User, where: u.username == ^username, preload: [:roles]))

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
    case Repo.one(from(u in User, where: u.username == ^username, preload: [:roles])) do
      nil -> {:error, :unknown_user}
      user -> {:ok, user}
    end
  end

  defp fetch_user_by_id(id) do
    case Repo.one(from(u in User, where: u.id == ^id, preload: [:roles])) do
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
    Repo.query!(
      "DELETE FROM users_roles WHERE user_id = ? AND role_id = (SELECT id FROM roles WHERE name = ?)",
      [
        user.id,
        role_name
      ]
    )

    :ok
  end

  defp ensure_role(name) do
    case Repo.one(from(r in Role, where: r.name == ^name)) do
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

  # -+
  # Рейтинги (Elo)
  # -------------------------------------------------------------------------

  @doc "Рейтинг игрока в игре; `:error`, если матчей ещё не было."
  @spec get_rating(integer(), String.t()) :: {:ok, integer()} | :error
  def get_rating(user_id, game \\ "default") when is_integer(user_id) do
    case Repo.get_by(Rating, user_id: user_id, game: game) do
      nil -> :error
      %Rating{} = row -> {:ok, row.rating}
    end
  end

  @doc """
  Фиксирует результат матча и пересчитывает рейтинги (Elo, K=32).

      Account.record_match("arena", %{1 => :win, 2 => :loss, 3 => :draw})

  `results` — `%{user_id => :win | :loss | :draw}`. Каждый участник
  «играет против каждого»: новый рейтинг = old + K/(n−1) · Σ(S − E),
  где S — фактический исход (1/0.5/0), E — ожидание по Elo. Неизвестный
  `user_id` — `{:error, {:unknown_user, id}}`. Возвращает
  `{:ok, %{user_id => новый_рейтинг}}`.
  """
  @spec record_match(String.t(), %{integer() => :win | :loss | :draw}) ::
          {:ok, %{integer() => integer()}} | {:error, term()}
  def record_match(game, results) when is_binary(game) and is_map(results) do
    with :ok <- validate_results(results),
         {:ok, new_ratings} <-
           Repo.transaction(fn ->
             rows = fetch_rows!(game, Map.keys(results))
             new_ratings = elo_new_ratings(rows, results)

             Enum.each(rows, fn row ->
               Repo.update!(
                 Rating.changeset(row, %{
                   rating: Map.fetch!(new_ratings, row.user_id),
                   wins: row.wins + outcome_count(row.user_id, results, :win),
                   losses: row.losses + outcome_count(row.user_id, results, :loss),
                   draws: row.draws + outcome_count(row.user_id, results, :draw)
                 })
               )
             end)

             Repo.insert!(
               MatchResult.changeset(%MatchResult{}, %{
                 game: game,
                 results:
                   Map.new(results, fn {uid, outcome} ->
                     {to_string(uid), to_string(outcome)}
                   end)
               })
             )

             new_ratings
           end),
         do: {:ok, new_ratings}
  end

  defp validate_results(results) do
    if map_size(results) < 2 do
      {:error, :need_two_players}
    else
      Enum.find_value(results, :ok, fn
        {uid, outcome} when is_integer(uid) and outcome in [:win, :loss, :draw] -> nil
        bad -> {:error, {:bad_result, bad}}
      end)
    end
  end

  defp fetch_rows!(game, user_ids) do
    Enum.map(user_ids, fn uid ->
      unless Repo.get(User, uid), do: Repo.rollback({:unknown_user, uid})

      Repo.get_by(Rating, user_id: uid, game: game) ||
        Repo.insert!(Rating.changeset(%Rating{}, %{user_id: uid, game: game}))
    end)
  end

  defp elo_new_ratings(rows, results) do
    uids = Map.keys(results)
    n = length(uids)
    rating = Map.new(rows, fn row -> {row.user_id, row.rating} end)

    deltas =
      for a <- uids, b <- uids, a != b, reduce: Map.new(uids, fn uid -> {uid, 0.0} end) do
        acc ->
          s = score(Map.get(results, a), Map.get(results, b))
          e = 1 / (1 + :math.pow(10, (rating[b] - rating[a]) / 400))
          Map.update!(acc, a, &(&1 + s - e))
      end

    Map.new(uids, fn uid ->
      {uid, round(Map.fetch!(rating, uid) + @k_factor / (n - 1) * Map.fetch!(deltas, uid))}
    end)
  end

  # очки a против b
  defp score(same, same), do: 0.5
  defp score(:win, _b), do: 1.0
  defp score(:draw, _b), do: 0.5
  defp score(:loss, _b), do: 0.0

  defp outcome_count(uid, results, outcome) do
    if Map.get(results, uid) == outcome, do: 1, else: 0
  end

  # -------------------------------------------------------------------------
  # Лидерборды
  # -------------------------------------------------------------------------

  @doc """
  Топ-N игроков по рейтингу в игре (позиции с 1). Сортировка детерминированная:
  рейтинг по убыванию, при равенстве — меньший user_id выше.

      Account.top_ratings("arena", 10)
      #=> [%{position: 1, user_id: 7, username: "ann", rating: 1120, ...}, ...]
  """
  @spec top_ratings(String.t(), non_neg_integer()) :: [map()]
  def top_ratings(game \\ "default", limit \\ 50) when is_binary(game) and is_integer(limit) do
    from(r in Rating,
      join: u in User,
      on: u.id == r.user_id,
      where: r.game == ^game,
      order_by: [desc: r.rating, asc: r.user_id],
      limit: ^limit,
      select: %{
        user_id: r.user_id,
        username: u.username,
        rating: r.rating,
        wins: r.wins,
        losses: r.losses,
        draws: r.draws
      }
    )
    |> Repo.all()
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, position} -> Map.put(entry, :position, position) end)
  end

  @doc """
  Позиция игрока в игре (1 — первое место; порядок как в `top_ratings/2`).
  `{:error, :not_found}`, если матчей ещё не было.
  """
  @spec rating_position(integer(), String.t()) :: {:ok, pos_integer()} | {:error, :not_found}
  def rating_position(user_id, game \\ "default") when is_integer(user_id) do
    case Repo.one(
           from(r in Rating,
             where: r.user_id == ^user_id and r.game == ^game,
             select: r.rating
           )
         ) do
      nil ->
        {:error, :not_found}

      rating ->
        ahead =
          Repo.one(
            from(r in Rating,
              where: r.game == ^game and
                       (r.rating > ^rating or (r.rating == ^rating and r.user_id < ^user_id)),
              select: count()
            )
          )

        {:ok, ahead + 1}
    end
  end

  # -------------------------------------------------------------------------
  # Cloud saves
  # -------------------------------------------------------------------------

  @doc """
  Сохраняет payload в слот `key` (upsert: повторный вызов заменяет payload).

      Account.save_data(user.id, "world1", %{"level" => 3, "note" => "привет"})
  """
  @spec save_data(integer(), String.t(), map()) :: result(Save.t())
  def save_data(user_id, key, payload) when is_integer(user_id) and is_binary(key) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %Save{}
    |> Save.changeset(%{user_id: user_id, key: key, payload: payload})
    |> Repo.insert(
      on_conflict: [set: [payload: payload, updated_at: now]],
      conflict_target: [:user_id, :key]
    )
    |> case do
      {:ok, save} -> {:ok, save}
      {:error, changeset} -> {:error, changeset_errors(changeset)}
    end
  end

  @doc "Читает payload слота; `{:error, :not_found}`, если слота нет."
  @spec get_save(integer(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_save(user_id, key) when is_integer(user_id) and is_binary(key) do
    case Repo.get_by(Save, user_id: user_id, key: key) do
      nil -> {:error, :not_found}
      %Save{payload: payload} -> {:ok, payload}
    end
  end

  @doc "Список слотов пользователя (ключи и время обновления, без payload)."
  @spec list_saves(integer()) :: [%{key: String.t(), updated_at: NaiveDateTime.t()}]
  def list_saves(user_id) when is_integer(user_id) do
    Repo.all(
      from(s in Save,
        where: s.user_id == ^user_id,
        order_by: [desc: s.updated_at],
        select: %{key: s.key, updated_at: s.updated_at}
      )
    )
  end

  @doc "Удаляет слот; `:error`, если слота не было."
  @spec delete_save(integer(), String.t()) :: :ok | {:error, :not_found}
  def delete_save(user_id, key) when is_integer(user_id) and is_binary(key) do
    {count, _} = Repo.delete_all(from(s in Save, where: s.user_id == ^user_id and s.key == ^key))

    if count > 0, do: :ok, else: {:error, :not_found}
  end
end
