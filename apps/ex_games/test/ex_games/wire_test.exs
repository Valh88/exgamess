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
          room_response: 22
        ] do
      assert Wire.opcode_number(name) == code
      assert Wire.opcode_name(code) == name
    end

    assert Wire.opcode_name(1) == :unknown
  end
end
