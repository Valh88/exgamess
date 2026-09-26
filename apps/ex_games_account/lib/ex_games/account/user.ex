defmodule ExGames.Account.User do
  @moduledoc "Пользователь: логин, хэш пароля, бан, роли (m2m)."

  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field(:username, :string)
    field(:password, :string, virtual: true, redact: true)
    field(:password_hash, :string, redact: true)
    field(:banned_at, :utc_datetime)
    field(:ban_reason, :string)

    many_to_many(:roles, ExGames.Account.Role,
      join_through: "users_roles",
      on_replace: :delete
    )

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password])
    |> validate_required([:username, :password])
    |> validate_username()
    |> validate_length(:password, min: 6, max: 128)
    |> put_password_hash()
  end

  def ban_changeset(user, attrs) do
    user
    |> cast(attrs, [:ban_reason])
    |> validate_required([:ban_reason])
    |> put_change(:banned_at, DateTime.utc_now(:second))
  end

  @doc "Публичный профиль (wire-формат для JSON/протокола)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = user) do
    %{
      "id" => user.id,
      "username" => user.username,
      "roles" => roles_to_wire(user.roles),
      "banned_at" => dt_to_wire(user.banned_at)
    }
  end

  defp validate_username(changeset) do
    changeset
    |> validate_length(:username, min: 3, max: 32)
    |> validate_format(:username, ~r/^[A-Za-z0-9_-]+$/,
      message: "only letters, digits, underscore and dash"
    )
    |> unique_constraint(:username)
  end

  defp put_password_hash(%Ecto.Changeset{valid?: true, changes: %{password: password}} = cs) do
    put_change(cs, :password_hash, Pbkdf2.hash_pwd_salt(password))
  end

  defp put_password_hash(cs), do: cs

  @doc false
  def roles_to_wire(roles), do: Enum.map(roles, & &1.name)

  @doc false
  def dt_to_wire(nil), do: nil
  def dt_to_wire(dt), do: DateTime.to_iso8601(dt)
end
