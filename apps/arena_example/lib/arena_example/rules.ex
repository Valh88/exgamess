defmodule ArenaExample.Rules do
  @moduledoc """
  Правила демо-арены как встраиваемый модуль логики (`ExGames.Room.Logic`).

  Держит срез состояния (игроки, счёт, тик), рассылает события и публикует
  снапшот состояния через `set_state/2`. Комната-оболочка
  (`ArenaExample.ArenaRoom`) подключает его строкой `logic: [__MODULE__]`
  и не содержит игровой логики.

  Сообщения клиента:

    * `{"move", %{"x" => x, "y" => y}}` — обновить позицию (уходит всем);
    * `{"hit", %{"target" => session_id}}` — добавить очко цели.
  """

  use ExGames.Room.Logic

  @impl true
  def logic_init(options, _room) do
    {:ok, %{mode: Map.get(options, "mode", "default"), players: %{}, scores: %{}, tick: 0}}
  end

  @impl true
  def logic_join(room, client, auth, state) do
    username = username(client, auth)

    broadcast(room, "player_joined", %{"session_id" => client.session_id, "username" => username})

    state =
      state
      |> put_in([:players, client.session_id], %{"x" => 0, "y" => 0, "name" => username})
      |> put_in([:scores, client.session_id], 0)

    publish(room, state)
    {:ok, state}
  end

  @impl true
  def logic_leave(room, client, _reason, state) do
    broadcast(room, "player_left", %{"session_id" => client.session_id})

    state = %{
      state
      | players: Map.delete(state.players, client.session_id),
        scores: Map.delete(state.scores, client.session_id)
    }

    publish(room, state)
    {:ok, state}
  end

  @impl true
  def logic_tick(_elapsed, state), do: {:ok, %{state | tick: state.tick + 1}}

  message "move", %{"x" => x, "y" => y}, room, client, state do
    x = clamp(x)
    y = clamp(y)

    state =
      put_in(
        state,
        [:players, client.session_id],
        %{"x" => x, "y" => y, "name" => state.players[client.session_id]["name"]}
      )

    broadcast(room, "moved", %{"session_id" => client.session_id, "x" => x, "y" => y})
    publish(room, state)
    {:ok, state}
  end

  message "hit", %{"target" => target}, room, client, state do
    if Map.has_key?(state.players, target) do
      state = Map.update!(state, :scores, &Map.update(&1, target, 1, fn s -> s + 1 end))

      broadcast(room, "hit", %{
        "by" => client.session_id,
        "target" => target,
        "score" => state.scores[target]
      })

      publish(room, state)
      {:ok, state}
    else
      {:ok, state}
    end
  end

  # -------------------------------------------------------------------------

  defp publish(room, state) do
    set_state(room, %{
      "mode" => state.mode,
      "tick" => state.tick,
      "players" => state.players,
      "scores" => state.scores
    })
  end

  defp username(client, auth) do
    case auth do
      %{"username" => u} when is_binary(u) -> u
      _ -> client.session_id
    end
  end

  defp clamp(v) when is_number(v), do: v |> max(-100) |> min(100)
  defp clamp(_), do: 0
end
