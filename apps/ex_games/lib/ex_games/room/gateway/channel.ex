defmodule ExGames.Room.Gateway.Channel do
  @moduledoc """
  Канал gateway: соответствие «комната ↔ сессия» на общем сокете одного
  клиента. `proxy` — процесс `ExGames.Room.Gateway.Proxy`, прикреплённый
  к комнате как транспорт; `monitor` — монитор прокси в процессе gateway.
  """

  defstruct [:room_id, :session_id, :proxy, :monitor]

  @type t :: %__MODULE__{
          room_id: ExGames.Id.id(),
          session_id: ExGames.Id.id(),
          proxy: pid(),
          monitor: reference()
        }
end
