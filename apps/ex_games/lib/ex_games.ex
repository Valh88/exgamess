defmodule ExGames do
  @moduledoc """
  Расширяемый master-server фреймворк для онлайн-игр.

  Публичный фасад ядра (делегирует в подсистемы через `defdelegate`).
  Комнаты объявляются через `use ExGames.Room`, регистрируются в
  матчмейкере (`ExGames.define_room/3`), клиенты проходят двухфазное
  подключение:

      1. `POST /matchmake/:method/:room_name` (HTTP JSON) → seat reservation
      2. `WS /ws/:room_id?sessionId=...` — бинарные кадры `[opcode u8][msgpack]`

  Полная спецификация протокола — `PROTOCOL.md` в корне репозитория.
  """
end
