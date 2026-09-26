defmodule ArenaExample.Application do
  @moduledoc """
  Boot демо-игры: регистрирует типы комнат в матчмейкере и стартует
  системную лобби-комнату. Схема подтверждает расширяемость фреймворка —
  игра объявляет себя без правок ядра.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ArenaExample.Boot
    ]

    opts = [strategy: :one_for_one, name: ArenaExample.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
