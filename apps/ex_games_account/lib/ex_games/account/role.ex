defmodule ExGames.Account.Role do
  @moduledoc "Роль RBAC: `player` | `moderator` | `admin` (расширяемо)."

  use Ecto.Schema

  @builtin [:player, :moderator, :admin]

  schema "roles" do
    field(:name, :string)

    timestamps(type: :utc_datetime)
  end

  def changeset(role, attrs) do
    role
    |> Ecto.Changeset.cast(attrs, [:name])
    |> Ecto.Changeset.validate_required([:name])
    |> Ecto.Changeset.unique_constraint(:name)
  end

  @doc "Список встроенных ролей."
  @spec builtin() :: [atom()]
  def builtin, do: @builtin

  @doc "Встроенная роль по имени (nil, если не встроенная)."
  @spec builtin(String.t() | atom()) :: atom() | nil
  def builtin(name) when is_atom(name), do: if(name in @builtin, do: name)
  def builtin(name) when is_binary(name), do: builtin(String.to_existing_atom(name))
end
