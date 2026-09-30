defmodule ArenaExample.SyncChatIntegrationTest do
  @moduledoc """
  Интеграционный тест Sync-чата (логика — `gamessa.script.Sync` с
  типизированными @:rpc, чанк `haxe -lua`, тип комнаты "sync_chat"):
  join-эффект с версией логики, say виден обоим, request-методы `seq`
  и `history` отвечают значением (кадр RoomResponse), схема возвращает
  типы из @:rpc, неизвестный запрос — ошибка с request_id.
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

  defp ensure_web! do
    {:ok, _} = Application.ensure_all_started(:ex_games_web)
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

  test "sync chat: join → say обоим → request seq/history значением → schema" do
    token_a = register!("sya_#{System.unique_integer([:positive])}")
    token_b = register!("syb_#{System.unique_integer([:positive])}")

    res_a = post!("/api/matchmake/join_or_create/sync_chat", token_a, %{})
    res_b = post!("/api/matchmake/join_or_create/sync_chat", token_b, %{})

    assert res_a["room_id"] == res_b["room_id"]

    {:ok, ca} = ws(res_a)
    {:ok, cb} = ws(res_b)

    # join-эффект: имя из auth + версия Sync-логики (v=2 — чат ChatHx даёт v=1)
    {:room_data, "joined", joined} =
      ExGamesWeb.Test.WsClient.wait_where(ca, fn
        {:room_data, "joined", %{"sid" => sid}} -> sid == res_a["session_id"]
        _ -> false
      end)

    assert joined["v"] == 2
    assert is_binary(joined["name"]) and joined["name"] != ""

    # say: broadcast обоим
    ExGamesWeb.Test.WsClient.send_binary(
      ca,
      Wire.encode(:room_data, {"say", %{"text" => "привет из sync!"}})
    )

    say_a = wait_frame(ca, "say")
    assert say_a["text"] == "привет из sync!"
    assert say_a["sid"] == res_a["session_id"]
    assert say_a["n"] == 1

    say_b = wait_frame(cb, "say")
    assert say_b["n"] == 1

    # request-метод seq(): значение-ответ кадром RoomResponse
    ExGamesWeb.Test.WsClient.send_binary(ca, Wire.encode(:room_request, {1, "seq", %{}}))

    assert {:room_response, 1, seq} =
             ExGamesWeb.Test.WsClient.wait_frame(ca, {:room_response, 1})

    assert seq == 1

    # request-метод history(): документ состояния
    ExGamesWeb.Test.WsClient.send_binary(cb, Wire.encode(:room_request, {2, "history", %{}}))

    assert {:room_response, 2, history} =
             ExGamesWeb.Test.WsClient.wait_frame(cb, {:room_response, 2})

    assert history["1"]["text"] == "привет из sync!"
    assert history["1"]["sid"] == res_a["session_id"]

    # schema: messages — имена @:rpc (send и request вместе)
    ExGamesWeb.Test.WsClient.send_binary(ca, Wire.encode(:room_request, {3, "schema", %{}}))

    assert {:room_response, 3, %{"messages" => messages, "state" => state_schema}} =
             ExGamesWeb.Test.WsClient.wait_frame(ca, {:room_response, 3})

    assert Enum.sort(messages) == ["history", "say", "seq"]
    assert state_schema["seq"] == "number"
    assert state_schema["users"]["map"] == "string"

    # неизвестный запрос — ошибка с request_id (клиент отклоняет мгновенно)
    ExGamesWeb.Test.WsClient.send_binary(ca, Wire.encode(:room_request, {4, "nope", %{}}))

    assert {:error, %{"code" => 526, "message" => "unknown request", "request_id" => 4}} =
             ExGamesWeb.Test.WsClient.wait_frame(ca, :error)

    # leave второго — первому уходит "left" (onLeave)
    ExGamesWeb.Test.WsClient.send_binary(cb, Wire.encode(:leave_room))
    assert %{"sid" => left_sid} = wait_frame(ca, "left", 3000)
    assert left_sid == res_b["session_id"]

    ExGamesWeb.Test.WsClient.stop(ca)
  end

  # -------------------------------------------------------------------------
  # Хелперы
  # -------------------------------------------------------------------------

  defp ws(res) do
    ExGamesWeb.Test.WsClient.start_link(
      "ws://127.0.0.1:#{@port}",
      res["room_id"],
      res["session_id"]
    )
  end

  defp wait_frame(client, type, timeout \\ 2000) do
    {:room_data, ^type, payload} =
      ExGamesWeb.Test.WsClient.wait_frame(client, {:room_data, type}, timeout)

    payload
  end

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
