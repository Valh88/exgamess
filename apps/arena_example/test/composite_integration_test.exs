defmodule ArenaExample.CompositeIntegrationTest do
  @moduledoc """
  Интеграционный тест композитного бандла (тип комнаты "composite"):
  два Haxe-модуля (Score + Ticker) в ОДНОМ чанке и одной VM. Проверяем
  merged-состояние с ветками, роутинг сообщений владельцу, catch-all,
  request-значение и тики обоих модулей — через настоящий HTTP/WS.
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

  test "composite bundle: ветки состояния, роутинг, request, catch-all, тики" do
    token = register!("cmp_#{System.unique_integer([:positive])}")
    res = post!("/api/matchmake/join_or_create/composite", token, %{})
    {:ok, c} = ws(res)

    # первый ROOM_STATE — полный снапшот с ветками ОБОИХ модулей
    assert {:room_state, state} = ExGamesWeb.Test.WsClient.wait_frame(c, :room_state, 3000)
    assert %{"score" => %{"points" => 0, "ticked" => 0}, "ticker" => %{"ticks" => 0}} = state

    # message "score" → модуль-владелец: broadcast с новым счётом
    ExGamesWeb.Test.WsClient.send_binary(c, Wire.encode(:room_data, {"score", %{"add" => 5}}))
    payload = wait_frame(c, "score")

    assert %{"points" => 5, "sid" => sid, "v" => 1} = payload
    assert sid == res["session_id"]

    # request → значение-ответ из модуля Score
    ExGamesWeb.Test.WsClient.send_binary(c, Wire.encode(:room_request, {7, "score_get", %{}}))
    assert {:room_response, 7, 5} = ExGamesWeb.Test.WsClient.wait_frame(c, {:room_response, 7})

    # неизвестный тип → catch-all (Ticker): молча, но unknown растёт в стейте
    ExGamesWeb.Test.WsClient.send_binary(c, Wire.encode(:room_data, {"mystery", %{}}))
    assert wait_state_value(c, ["ticker", "unknown"], fn v -> is_number(v) and v >= 1 end)

    # тик-пайплайн: оба модуля advance в своих ветках (patch_rate 100)
    assert wait_state_value(c, ["score", "ticked"], fn v -> is_number(v) and v > 0 end)
    assert wait_state_value(c, ["ticker", "ticks"], fn v -> is_number(v) and v > 0 end)

    ExGamesWeb.Test.WsClient.stop(c)
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

  # Ждёт патч состояния, выставляющий значение по пути (delta-синк).
  # Патчи идемпотентны-присваивания: ищем op {"p": path, "v": value}.
  defp wait_state_value(client, path, pred, tries \\ 50)

  defp wait_state_value(_client, _path, _pred, 0), do: flunk("state value did not arrive")

  defp wait_state_value(client, path, pred, tries) do
    ExGamesWeb.Test.WsClient.send_binary(client, Wire.encode(:ping))

    frames =
      try do
        [ExGamesWeb.Test.WsClient.wait_frame(client, :room_state_patch, 300)]
      rescue
        RuntimeError -> []
      end

    found =
      Enum.any?(frames, fn {:room_state_patch, %{"ops" => ops}} ->
        Enum.any?(ops, fn
          %{"p" => ^path, "v" => v} -> pred.(v)
          _ -> false
        end)
      end)

    if found do
      :ok
    else
      Process.sleep(100)
      wait_state_value(client, path, pred, tries - 1)
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
