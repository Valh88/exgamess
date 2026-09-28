defmodule ExGamesWeb.Test.FakeTransport do
  @moduledoc false
  # Подставной транспорт для веб-тестов: копит кадры, отдаёт по запросу.

  def start_link do
    {:ok, spawn_link(fn -> loop([]) end)}
  end

  def attach!(room_id, session_id) do
    {:ok, transport} = start_link()

    {:ok, join_frame, state_frame} =
      ExGames.Room.Server.attach(room_id, session_id, transport, %{})

    {transport, join_frame, state_frame}
  end

  def frames(transport, timeout \\ 500) do
    ref = make_ref()
    send(transport, {:collect, self(), ref})

    receive do
      {^ref, frames} -> frames
    after
      timeout -> []
    end
  end

  defp loop(acc) do
    receive do
      {:collect, reply_to, ref} ->
        send(reply_to, {ref, Enum.reverse(acc)})
        loop(acc)

      {:ex_games_push, frame} ->
        loop([frame | acc])

      _ ->
        loop(acc)
    end
  end
end
