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

  require Logger

  # Очки до победы: по достижении матч завершается, результат уходит
  # в рейтинги аккаунтов (Elo) — см. record_result/2.
  @win_score 5

  @impl true
  def logic_init(options, _room) do
    # "game" — ключ рейтинга (очередь передаёт тип матч-комнаты);
    # "mode" — произвольный режим, оставлен для прямых create-вызовов.
    mode = Map.get(options, "game", Map.get(options, "mode", "default"))
    {:ok, %{mode: mode, players: %{}, scores: %{}, tick: 0}}
  end

  @impl true
  def logic_join(room, client, auth, state) do
    username = username(client, auth)

    broadcast(room, "player_joined", %{"session_id" => client.session_id, "username" => username})

    state =
      state
      |> put_in([:players, client.session_id], %{
        "x" => 0,
        "y" => 0,
        "name" => username,
        "user_id" => Map.get(auth, "user_id")
      })
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

      if state.scores[target] >= @win_score do
        broadcast(room, "game_over", %{"winner" => target, "score" => state.scores[target]})
        record_result(state, target)
        {:stop, :normal, state}
      else
        {:ok, state}
      end
    else
      {:ok, state}
    end
  end

  # -------------------------------------------------------------------------

  # Победа: исходы всех игроков (по user_id из auth) → рейтинги аккаунтов.
  # Игроки без user_id в рейтинги не попадают; матчей с меньше чем двумя
  # идентифицированными игроками рейтинг не касается.
  defp record_result(state, winner_sid) do
    results =
      state.players
      |> Map.new(fn {sid, info} ->
        {sid, Map.get(info, "user_id")}
      end)
      |> Enum.flat_map(fn
        {sid, user_id} when is_integer(user_id) -> [{user_id, outcome(sid, winner_sid)}]
        _ -> []
      end)
      |> Map.new()

    case map_size(results) >= 2 do
      true ->
        case ExGames.Account.record_match(state.mode, results) do
          {:ok, ratings} ->
            Logger.info("[arena_example] match rated: #{inspect(ratings)}")

          {:error, reason} ->
            Logger.warning("[arena_example] rating skipped: #{inspect(reason)}")
        end

      false ->
        Logger.warning("[arena_example] match result skipped: not enough identified players")
    end
  end

  defp outcome(sid, winner_sid) when sid == winner_sid, do: :win
  defp outcome(_sid, _winner_sid), do: :loss

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
