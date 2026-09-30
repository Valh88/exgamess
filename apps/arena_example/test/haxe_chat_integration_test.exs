defmodule ArenaExample.HaxeChatIntegrationTest do
  @moduledoc """
  Интеграционный тест Haxe-чата (логика — чанк `haxe -lua`, тип комнаты
  "haxe_chat"): два клиента через настоящий HTTP/WS — join-эффект с
  именем и версией логики, say виден обоим, история приходит лично
  через эффект send_to, уход второго — эффект left.
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

  test "haxe chat: join → say виден обоим → history лично → left" do
    token_a = register!("hxa_#{System.unique_integer([:positive])}")
    token_b = register!("hxb_#{System.unique_integer([:positive])}")

    res_a = post!("/api/matchmake/join_or_create/haxe_chat", token_a, %{})
    res_b = post!("/api/matchmake/join_or_create/haxe_chat", token_b, %{})

    assert is_binary(res_a["room_id"])
    assert res_a["room_id"] == res_b["room_id"]

    {:ok, ca} = ws(res_a)
    {:ok, cb} = ws(res_b)

    # join-эффект из Haxe: имя из auth + версия логики (кадры "joined"
    # обоих участников могут прийти в любом порядке — ждём по sid)
    {:room_data, "joined", joined} =
      ExGamesWeb.Test.WsClient.wait_where(ca, fn
        {:room_data, "joined", %{"sid" => sid}} -> sid == res_a["session_id"]
        _ -> false
      end)

    assert joined["v"] == 1
    assert is_binary(joined["name"]) and joined["name"] != ""

    {:room_data, "joined", joined_b} =
      ExGamesWeb.Test.WsClient.wait_where(cb, fn
        {:room_data, "joined", %{"sid" => sid}} -> sid == res_b["session_id"]
        _ -> false
      end)

    assert joined_b["sid"] == res_b["session_id"]

    # say: эхо себе и broadcast второму (включая кириллицу — байт-точность)
    ExGamesWeb.Test.WsClient.send_binary(
      ca,
      Wire.encode(:room_data, {"say", %{"text" => "приват из haxe!"}})
    )

    say_a = wait_frame(ca, "say")
    assert say_a["text"] == "приват из haxe!"
    assert say_a["sid"] == res_a["session_id"]
    assert say_a["n"] == 1

    say_b = wait_frame(cb, "say")
    assert say_b["text"] == "приват из haxe!"

    # request "schema" — типизированная схема из typedef ChatState
    ExGamesWeb.Test.WsClient.send_binary(
      ca,
      Wire.encode(:room_request, {42, "schema", %{}})
    )

    assert {:room_response, 42, %{"messages" => messages, "state" => state_schema}} =
             ExGamesWeb.Test.WsClient.wait_frame(ca, {:room_response, 42})

    assert Enum.sort(messages) == ["history", "say"]
    assert state_schema["seq"] == "number"
    assert state_schema["users"]["map"] == "string"
    assert state_schema["history"]["map"]["text"] == "string"

    # history — только отправителю (эффект send_to); второму кадра нет
    ExGamesWeb.Test.WsClient.send_binary(
      ca,
      Wire.encode(:room_data, {"history", %{}})
    )

    hist = wait_frame(ca, "history")
    assert map_size(hist["history"]) == 1
    assert hist["history"]["1"]["text"] == "приват из haxe!"
    assert hist["history"]["1"]["name"] == say_a["name"]
    assert_no_frame(cb, "history")

    # leave: второй уходит кадром leave_room (обрыв сокета давал бы
    # reconnect-слот, а не leave) — первому уходит "left"
    ExGamesWeb.Test.WsClient.send_binary(cb, Wire.encode(:leave_room))
    assert %{"sid" => left_sid} = wait_frame(ca, "left", 3000)
    assert left_sid == res_b["session_id"]

    ExGamesWeb.Test.WsClient.stop(ca)
  end

  # -------------------------------------------------------------------------
  # Хелперы
  # -------------------------------------------------------------------------

  defp ws(res) do
    ExGamesWeb.Test.WsClient.start_link("ws://127.0.0.1:#{@port}", res["room_id"], res["session_id"])
  end

  defp wait_frame(client, type, timeout \\ 2000) do
    {:room_data, ^type, payload} =
      ExGamesWeb.Test.WsClient.wait_frame(client, {:room_data, type}, timeout)

    payload
  end

  defp assert_no_frame(client, type) do
    try do
      ExGamesWeb.Test.WsClient.wait_frame(client, {:room_data, type}, 300)
      flunk("unexpected #{type} frame at second client")
    rescue
      RuntimeError -> :ok
    end
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
