defmodule ArenaExample.ArenaIntegrationTest do
  @moduledoc """
  Интеграционный тест демо-игры через настоящий HTTP/WS:
  Boot регистрирует комнаты → регистрация → matchmake арены → WS-подключение →
  move → room_state. Полный пользовательский сценарий master-server'а.
  """

  use ExUnit.Case, async: false

  alias ExGames.Wire

  @port 4045
  @base "http://127.0.0.1:#{@port}"

  setup_all do
    ensure_web!()
    {:ok, _} = Application.ensure_all_started(:arena_example)
    :ok
  end

  # В umbrella-прогоне endpoint веб-приложения мог погаснуть после его
  # собственного тест-прогона: проверяем листенер и при необходимости
  # перезапускаем веб-приложение.
  defp ensure_web! do
    {:ok, _} = Application.ensure_all_started(:ex_games_web)

    # Веб-тесты оставляют репо в Sandbox-режиме :manual — возвращаем auto,
    # иначе каждый HTTP-запрос падает с OwnershipError.
    Ecto.Adapters.SQL.Sandbox.mode(ExGames.Account.Repo, :auto)
    Ecto.Adapters.SQL.Sandbox.mode(ExGamesWeb.Repo, :auto)

    unless listening?(@port) do
      Application.stop(:ex_games_web)
      {:ok, _} = Application.ensure_all_started(:ex_games_web)
      wait_listener!(50)
    end

    :ok
  end

  defp listening?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 300) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      _ ->
        false
    end
  end

  defp wait_listener!(0), do: raise("listener did not come up")

  defp wait_listener!(tries) do
    if listening?(@port) do
      :ok
    else
      Process.sleep(100)
      wait_listener!(tries - 1)
    end
  end

  test "register → matchmake arena → ws join → move → state broadcast" do
    token = register!("demo_#{System.unique_integer([:positive])}")

    res =
      post!("/api/matchmake/join_or_create/arena", token, %{"options" => %{"mode" => "ranked"}})

    assert res["room_id"]

    {:ok, client} =
      ExGamesWeb.Test.WsClient.start_link(
        "ws://127.0.0.1:#{@port}",
        res["room_id"],
        res["session_id"]
      )

    assert {:join_room, %{"session_id" => sid}} =
             ExGamesWeb.Test.WsClient.wait_frame(client, :join_room)

    assert sid == res["session_id"]

    assert {:room_data, "player_joined", %{"session_id" => ^sid}} =
             ExGamesWeb.Test.WsClient.wait_frame(client, {:room_data, "player_joined"})

    # первый кадр состояния — полный снапшот (delta-режим арены)
    {:room_state, state} = ExGamesWeb.Test.WsClient.wait_frame(client, :room_state)
    assert state["mode"] == "ranked"
    assert state["players"][sid]

    # move → moved + патч состояния (только изменённые пути)
    ExGamesWeb.Test.WsClient.send_binary(
      client,
      Wire.encode(:room_data, {"move", %{"x" => 10, "y" => -5}})
    )

    assert {:room_data, "moved", %{"x" => 10, "y" => -5}} =
             ExGamesWeb.Test.WsClient.wait_frame(client, {:room_data, "moved"})

    state = wait_patch_apply(client, state)
    assert state["players"][sid]["x"] == 10
    assert state["players"][sid]["y"] == -5

    # hit по себе → счёт
    ExGamesWeb.Test.WsClient.send_binary(
      client,
      Wire.encode(:room_data, {"hit", %{"target" => sid}})
    )

    state = wait_patch_apply(client, state)
    assert state["scores"][sid] == 1

    ExGamesWeb.Test.WsClient.stop(client)
  end

  # ждёт кадр ROOM_STATE_PATCH и применяет операции к накопленному состоянию
  defp wait_patch_apply(client, state, timeout \\ 2000) do
    {:room_state_patch, %{"ops" => ops}} =
      ExGamesWeb.Test.WsClient.wait_frame(client, :room_state_patch, timeout)

    Enum.reduce(ops, state, fn op, acc ->
      if op["d"] == true do
        delete_in(acc, op["p"])
      else
        put_path(acc, op["p"], op["v"])
      end
    end)
  end

  defp put_path(map, [k], v) when is_map(map), do: Map.put(map, k, v)
  defp put_path(map, [k | rest], v), do: Map.put(map, k, put_path(Map.fetch!(map, k), rest, v))

  defp delete_in(map, [k]) when is_map(map), do: Map.delete(map, k)
  defp delete_in(map, [k | rest]), do: Map.put(map, k, delete_in(Map.fetch!(map, k), rest))

  test "chat room works end to end" do
    token = register!("chatter_#{System.unique_integer([:positive])}")

    res =
      post!("/api/matchmake/join_or_create/chat", token, %{
        "options" => %{"channel" => "global"}
      })

    {:ok, client} =
      ExGamesWeb.Test.WsClient.start_link(
        "ws://127.0.0.1:#{@port}",
        res["room_id"],
        res["session_id"]
      )

    _ = ExGamesWeb.Test.WsClient.wait_frame(client, {:room_data, "joined"})

    ExGamesWeb.Test.WsClient.send_binary(
      client,
      Wire.encode(:room_data, {"say", %{"text" => "gg"}})
    )

    assert {:room_data, "say", %{"text" => "gg"}} =
             ExGamesWeb.Test.WsClient.wait_frame(client, {:room_data, "say"})

    ExGamesWeb.Test.WsClient.stop(client)
  end

  test "queue pairs two players into seats" do
    t1 = register!("q_#{System.unique_integer([:positive])}")
    t2 = register!("q_#{System.unique_integer([:positive])}")

    q1 = post!("/api/matchmake/join_or_create/queue", t1, %{"options" => %{"rank" => 1500}})
    q2 = post!("/api/matchmake/join_or_create/queue", t2, %{"options" => %{"rank" => 1550}})

    {:ok, c1} =
      ExGamesWeb.Test.WsClient.start_link(
        "ws://127.0.0.1:#{@port}",
        q1["room_id"],
        q1["session_id"]
      )

    {:ok, c2} =
      ExGamesWeb.Test.WsClient.start_link(
        "ws://127.0.0.1:#{@port}",
        q2["room_id"],
        q2["session_id"]
      )

    # оба дождались "seat" с room_id арены (тиком очереди)
    seat1 = ExGamesWeb.Test.WsClient.wait_frame(c1, {:room_data, "seat"}, 5000)
    seat2 = ExGamesWeb.Test.WsClient.wait_frame(c2, {:room_data, "seat"}, 5000)

    assert {:room_data, "seat", %{"room_id" => arena_id1}} = seat1
    assert {:room_data, "seat", %{"room_id" => arena_id2}} = seat2
    assert arena_id1 == arena_id2

    ExGamesWeb.Test.WsClient.stop(c1)
    ExGamesWeb.Test.WsClient.stop(c2)
  end

  # -------------------------------------------------------------------------
  # HTTP helpers
  # -------------------------------------------------------------------------

  defp register!(username) do
    case Req.post("#{@base}/api/auth/register",
           json: %{"username" => username, "password" => "secret123"}
         ) do
      {:ok, %{status: 201, body: %{"token" => token}}} ->
        token

      _ ->
        {:ok, %{body: %{"token" => token}}} =
          Req.post("#{@base}/api/auth/login",
            json: %{"username" => username, "password" => "secret123"}
          )

        token
    end
  end

  defp post!(path, token, json) do
    {:ok, resp} =
      Req.post("#{@base}#{path}",
        json: json,
        headers: [{"authorization", "Bearer #{token}"}]
      )

    resp.body
  end
end
