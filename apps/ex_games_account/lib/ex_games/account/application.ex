defmodule ExGames.Account.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ExGames.Account.Repo
    ]

    opts = [strategy: :one_for_one, name: ExGames.Account.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
