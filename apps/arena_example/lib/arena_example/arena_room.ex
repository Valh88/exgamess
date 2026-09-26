defmodule ArenaExample.ArenaRoom do
  @moduledoc """
  Демо-арена: до 8 игроков, тик 50 мс, движение и счёт.

  Сообщения клиента:

    * `{"move", %{"x" => x, "y" => y}}` — обновить позицию (уходит всем);
    * `{"hit", %{"target" => session_id}}` — добавить очко цели.

  Состояние рассылается всем каждый тик (`room_state`, полный снапшот).
  Демонстрирует DSL `use ExGames.Room`: `message`-клаузы, `broadcast`,
  `set_state`, lifecycle.
  """

  use ExGames.Room, max_clients: 8, patch_rate: 50

  @impl true
  def room_init(options, _room) do
    mode = Map.get(options, "mode", "default")

    {:ok,
     %{
       mode: mode,
       players: %{},
       # счёт по сессиям
       scores: %{},
       tick: 0
     }}
  end

  @impl true
  def handle_join(room, client, auth, state) do
    username =
      case auth do
        %{"username" => u} when is_binary(u) -> u
        _ -> client.session_id
      end

    broadcast(room, "player_joined", %{"session_id" => client.session_id, "username" => username})

    state = %{
      state
      | players: Map.put(state.players, client.session_id, %{"x" => 0, "y" => 0, "name" => username}),
        scores: Map.put(state.scores, client.session_id, 0)
    }

    publish(room, state)
    {:ok, state}
  end

  @impl true
  def handle_leave(room, client, _reason, state) do
    broadcast(room, "player_left", %{"session_id" => client.session_id})

    state = %{
      state
      | players: Map.delete(state.players, client.session_id),
        scores: Map.delete(state.scores, client.session_id)
    }

    publish(room, state)
    {:ok, state}
  end

  message "move", %{"x" => x, "y" => y}, room, client, state do
    x = clamp(x)
    y = clamp(y)

    state =
      put_in(state, [:players, client.session_id], %{
        "x" => x,
        "y" => y,
        "name" => state.players[client.session_id]["name"]
      })

    broadcast(room, "moved", %{"session_id" => client.session_id, "x" => x, "y" => y})
    publish(room, state)
    {:ok, state}
  end

  message "hit", %{"target" => target}, room, client, state do
    if Map.has_key?(state.players, target) do
      state = Map.update!(state, :scores, &Map.update(&1, target, 1, fn s -> s + 1 end))

      broadcast(room, "hit", %{"by" => client.session_id, "target" => target, "score" => state.scores[target]})
      publish(room, state)
      {:ok, state}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_tick(_dt, state) do
    {:ok, %{state | tick: state.tick + 1}}
  end

  defp publish(room, state) do
    wire_state = %{
      "mode" => state.mode,
      "tick" => state.tick,
      "players" => state.players,
      "scores" => state.scores
    }

    set_state(room, wire_state)
  end

  defp clamp(v) when is_number(v), do: v |> max(-100) |> min(100)
  defp clamp(_), do: 0
end
