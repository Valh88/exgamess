defmodule ExGames.WireTest do
  use ExUnit.Case, async: true

  alias ExGames.Wire

  describe "encode/decode roundtrip" do
    test "ping is a single byte" do
      frame = Wire.encode(:ping)
      assert <<18>> == frame
      assert {:ok, {:ping}} == Wire.decode(frame)
    end

    test "ping carries optional payload (синхронизация времени)" do
      frame = Wire.encode(:ping, %{"t" => 12345.5})
      assert <<18, _::binary>> = frame
      assert {:ok, {:ping, %{"t" => 12345.5}}} = Wire.decode(frame)
    end

    test "leave_room is a single byte" do
      frame = Wire.encode(:leave_room)
      assert <<12>> == frame
      assert {:ok, {:leave_room}} == Wire.decode(frame)
    end

    test "room_data with string type and map payload" do
      frame = Wire.encode(:room_data, {"move", %{"x" => 1, "y" => 2.5, "name" => "tier"}})
      assert <<13, _::binary>> = frame

      assert {:ok, {:room_data, "move", %{"x" => 1, "y" => 2.5, "name" => "tier"}}} =
               Wire.decode(frame)
    end

    test "room_data with integer type" do
      frame = Wire.encode(:room_data, {7, [1, 2, 3]})
      assert {:ok, {:room_data, 7, [1, 2, 3]}} = Wire.decode(frame)
    end

    test "join_room carries options" do
      frame = Wire.encode(:join_room, %{"room_id" => "abc", "session_id" => "s1"})
      assert {:ok, {:join_room, %{"room_id" => "abc", "session_id" => "s1"}}} = Wire.decode(frame)
    end

    test "room_state roundtrips nested structures" do
      state = %{"players" => [%{"id" => "a", "score" => 10}], "t" => 1_234}
      frame = Wire.encode(:room_state, state)
      assert <<14, _::binary>> = frame
      assert {:ok, {:room_state, ^state}} = Wire.decode(frame)
    end

    test "кириллица/юникод в payload ходит байт-в-байт" do
      # прикладной кейс: ник и текст сообщения на кириллице
      frame =
        Wire.encode(:room_data, {"say", %{"text" => "привет мир", "from" => "Николай"}})

      assert {:ok, {:room_data, "say", %{"text" => "привет мир", "from" => "Николай"}}} =
               Wire.decode(frame)

      # и в состоянии комнаты (дельта-синхронизация)
      state = %{"ник" => "Влад", "чат" => ["фыв", "Привет!"]}
      assert {:ok, {:room_state, ^state}} = Wire.decode(Wire.encode(:room_state, state))
    end

    test "room_request / room_response correlation" do
      request = Wire.encode(:room_request, {42, "whoami", %{"x" => 1}})
      assert {:ok, {:room_request, 42, "whoami", %{"x" => 1}}} = Wire.decode(request)

      response = Wire.encode(:room_response, {42, %{"you" => "s1"}})
      assert {:ok, {:room_response, 42, %{"you" => "s1"}}} = Wire.decode(response)
    end

    test "error frame with explicit code" do
      frame = Wire.encode(:error, %{code: 525, message: "auth failed"})
      assert {:ok, {:error, %{"code" => 525, "message" => "auth failed"}}} = Wire.decode(frame)
    end

    test "error frame with request_id (отклонение конкретного запроса)" do
      frame = Wire.encode(:error, %{code: 526, message: "internal error", request_id: 42})

      assert {:ok, {:error, %{"code" => 526, "message" => "internal error", "request_id" => 42}}} =
               Wire.decode(frame)
    end

    test "room_enter carries reservation" do
      frame =
        Wire.encode(:room_enter, %{room_id: "r1", session_id: "s1", reconnection_token: "tok"})

      assert <<23, _::binary>> = frame

      assert {:ok,
              {:room_enter,
               %{"room_id" => "r1", "session_id" => "s1", "reconnection_token" => "tok"}}} =
               Wire.decode(frame)
    end

    test "mux carries inner frame bytes verbatim" do
      inner = Wire.encode(:room_data, {"move", %{"x" => 1}})
      frame = Wire.encode(:mux, {"room9", inner})
      assert <<25, _::binary>> = frame

      assert {:ok, {:mux, "room9", ^inner}} = Wire.decode(frame)
    end

    test "mux inner frame survives non-utf8 and single-byte payloads" do
      for inner <- [<<12>>, <<18>>, <<13, 0xFF, 0x81, 0x00>>] do
        frame = Wire.encode(:mux, {"r", inner})
        assert {:ok, {:mux, "r", ^inner}} = Wire.decode(frame)
      end
    end

    test "muxClosed carries close code and message" do
      frame = Wire.encode(:mux_closed, {"room9", 4000, "client left"})
      assert <<26, _::binary>> = frame

      assert {:ok, {:mux_closed, "room9", 4000, "client left"}} = Wire.decode(frame)
    end
  end

  describe "decode errors" do
    test "empty frame" do
      assert {:error, :invalid_frame} = Wire.decode(<<>>)
    end

    test "unknown opcode" do
      assert {:error, :invalid_frame} = Wire.decode(<<99, 1, 2, 3>>)
    end

    test "truncated msgpack" do
      assert {:error, :invalid_frame} = Wire.decode(<<13, 0x81, 0xA3>>)
    end

    test "garbage payload" do
      assert {:error, :invalid_frame} = Wire.decode(<<13, 0xFF, 0xFF, 0xFF>>)
    end

    test "mux without f key" do
      assert {:error, :invalid_frame} = Wire.decode(<<25, 0x81, 0xA1, 0x72, 0xA1, 0x78>>)
    end

    test "mux_closed without code" do
      assert {:error, :invalid_frame} = Wire.decode(<<26, 0xFF>>)
    end
  end

  test "opcode_number/opcode_name are consistent" do
    for {name, code} <- [
          join_room: 10,
          error: 11,
          leave_room: 12,
          room_data: 13,
          room_state: 14,
          room_state_patch: 15,
          ping: 18,
          room_request: 21,
          room_response: 22,
          room_enter: 23,
          mux: 25,
          mux_closed: 26
        ] do
      assert Wire.opcode_number(name) == code
      assert Wire.opcode_name(code) == name
    end

    assert Wire.opcode_name(1) == :unknown
  end
end
