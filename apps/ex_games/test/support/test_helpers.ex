defmodule ExGames.RoomLifecycleTestHelpers do
  @moduledoc false
  # Хелперы ожидания кадров для интеграционных тестов ядра.

  alias ExGames.Wire

  @doc "Ждёт room_data заданного типа на транспорте FakeTransport."
  def wait(transport, type, tries \\ 50)

  def wait(_transport, _type, 0), do: raise("frame did not arrive")

  def wait(transport, type, tries) do
    frames = ExGames.Test.FakeTransport.frames(transport, 100)

    found =
      Enum.find(frames, fn frame ->
        case Wire.decode(frame) do
          {:ok, {:room_data, t, _payload}} -> t == type
          _ -> false
        end
      end)

    if found do
      found
    else
      Process.sleep(20)
      wait(transport, type, tries - 1)
    end
  end

  @doc "Ждёт room_response с заданным request_id."
  def wait_response(transport, request_id, tries \\ 50)

  def wait_response(_transport, _id, 0), do: raise("response did not arrive")

  def wait_response(transport, request_id, tries) do
    frames = ExGames.Test.FakeTransport.frames(transport, 100)

    found =
      Enum.find(frames, fn frame ->
        match?({:ok, {:room_response, ^request_id, _}}, Wire.decode(frame))
      end)

    if found do
      found
    else
      Process.sleep(20)
      wait_response(transport, request_id, tries - 1)
    end
  end
end
