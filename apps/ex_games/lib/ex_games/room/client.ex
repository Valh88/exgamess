defmodule ExGames.Room.Client do
  @moduledoc """
  Клиент комнаты: сессия, подключённая через транспорт (WebSocket).

  `pid` — процесс транспорта; комната пушит кадры ему сообщением
  `{:ex_games_push, frame :: binary()}`. Сам транспорт отвечает за
  доставку байт в сеть и за обработку закрытия.

  `reconnection_token` выдаётся при attach и передаётся клиенту в кадре
  `join_room`; после не-согласованного обрыва транспорта клиент может
  переподключиться по этому токену (`ExGames.Room.Server.reattach/4`).
  """

  @typedoc "Пользовательский auth-данные (результат `handle_auth`)."
  @type auth :: term()

  @type t :: %__MODULE__{
          session_id: ExGames.Id.id(),
          pid: pid(),
          auth: auth(),
          reconnection_token: ExGames.Id.id(),
          joined_at: DateTime.t()
        }

  defstruct [:session_id, :pid, :auth, :reconnection_token, joined_at: nil]

  @doc "Формат клиента для wire (в списках игроков и т.п.)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = client) do
    %{"session_id" => client.session_id}
  end
end
