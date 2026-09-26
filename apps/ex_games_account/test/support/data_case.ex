defmodule ExGames.Account.DataCase do
  @moduledoc """
  Тестовый кейс с SQL Sandbox для ExGames.Account.Repo.
  Каждый тест — своя транзакция, откат после завершения.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias ExGames.Account.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ExGames.Account.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
