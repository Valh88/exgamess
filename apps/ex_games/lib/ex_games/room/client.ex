defmodule ExGames.Room.Client do
  @moduledoc """
  Клиент комнаты: сессия, подключённая через транспорт (WebSocket).

  `pid` — процесс транспорта; комната пушит кадры ему сообщением
  `{:ex_games_push, frame :: binary()}`. Сам транспорт отвечает за
  доставку байт в сеть и за обработку закрытия.
  """

  @typedoc "Пользовательский auth-данные (результат `handle_auth`)."
  @type auth :: term()

  @type t :: %__MODULE__{
          session_id: ExGames.Id.id(),
          pid: pid(),
          auth: auth(),
          joined_at: DateTime.t()
        }

  defstruct [:session_id, :pid, :auth, joined_at: nil]

  @doc "Формат клиента для wire (в списках игроков и т.п.)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = client) do
    %{"session_id" => client.session_id}
  end
end
