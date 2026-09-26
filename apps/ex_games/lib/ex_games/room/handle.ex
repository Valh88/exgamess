defmodule ExGames.Room.Handle do
  @moduledoc """
  Лёгкий handle комнаты: единственный обязательный атрибут — `room_id`.
  Эффекты (`ExGames.Room.broadcast/3` и др.) адресуют комнату через Registry
  по этому идентификатору, поэтому handle можно хранить где угодно.
  """

  @type t :: %__MODULE__{room_id: ExGames.Id.id()}

  defstruct [:room_id]
end
