defmodule ExGames.Matchmaker.Reservation do
  @moduledoc """
  Бронь места в комнате (результат шага 1). Клиент использует `room_id` +
  `session_id` для подключения по WebSocket:

      WS /ws/:room_id?sessionId=:session_id
  """

  @type t :: %__MODULE__{
          room_name: String.t(),
          room_id: ExGames.Id.id(),
          session_id: ExGames.Id.id()
        }

  defstruct [:room_name, :room_id, :session_id]

  @doc "Формат брони для wire (HTTP JSON)."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = reservation) do
    %{
      "room_name" => reservation.room_name,
      "room_id" => reservation.room_id,
      "session_id" => reservation.session_id
    }
  end
end
