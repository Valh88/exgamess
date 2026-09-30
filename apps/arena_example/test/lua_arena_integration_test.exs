defmodule ArenaExample.LuaArenaIntegrationTest do
  @moduledoc """
  Интеграционный тест Lua-арены через настоящий HTTP/WS:
  Boot регистрирует lua_arena → регистрация → matchmake → WS-подключение →
  join-эффект скрипта → move/hit → патчи состояния → request "schema".
  Логика исполняется Lua-VM внутри BEAM (см. doc/LUA_SCRIPTING.md).
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

  test "register → matchmake lua_arena → ws join → move/hit → schema request" do
    token = register!("lua_#{System.unique_integer([:positive])}")

    res =
      post!("/api/matchmake/join_or_create/lua_arena", token, %{"options" => %{"mode" => "lua"}})

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

    # join-эффект из Lua-скрипта: broadcast "player_joined"
    assert {:room_data, "player_joined", %{"sid" => ^sid}} =
             ExGamesWeb.Test.WsClient.wait_frame(client, {:room_data, "player_joined"})

    # первый кадр состояния — полный снапшот от скрипта (delta-режим)
    {:room_state, state} = ExGamesWeb.Test.WsClient.wait_frame(client, :room_state)
    assert state["players"][sid]["hp"] == 100
    assert state["scores"][sid] == 0

    # move → эффект broadcast "moved" + патч состояния (только изменённые пути)
    ExGamesWeb.Test.WsClient.send_binary(
      client,
      Wire.encode(:room_data, {"move", %{"x" => 7, "y" => -3}})
    )

    assert {:room_data, "moved", %{"sid" => ^sid, "x" => 7, "y" => -3}} =
             ExGamesWeb.Test.WsClient.wait_frame(client, {:room_data, "moved"})

    state = wait_patch_apply(client, state)
    assert state["players"][sid]["x"] == 7
    assert state["players"][sid]["y"] == -3

    # hit по себе → счёт
    ExGamesWeb.Test.WsClient.send_binary(
      client,
      Wire.encode(:room_data, {"hit", %{"target" => sid}})
    )

    assert {:room_data, "hit", %{"by" => ^sid, "total" => 1}} =
             ExGamesWeb.Test.WsClient.wait_frame(client, {:room_data, "hit"})

    state = wait_patch_apply(client, state)
    assert state["scores"][sid] == 1

    # request "schema" → документ M.schema скрипта
    ExGamesWeb.Test.WsClient.send_binary(
      client,
      Wire.encode(:room_request, {42, "schema", %{}})
    )

    assert {:room_response, 42, %{"messages" => messages}} =
             ExGamesWeb.Test.WsClient.wait_frame(client, {:room_response, 42})

    assert Enum.sort(messages) == ["hit", "move"]

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
