defmodule ExGames.RoomGatewayTest do
  @moduledoc false
  # Ядро мультиплексирования: канал-прокси, маршрутизация, закрытие канала,
  # смерть транспорта → reconnect-слот, повторный вход по токену.

  use ExUnit.Case, async: true

  alias ExGames.Room.Gateway
  alias ExGames.Room.Server
  alias ExGames.Rooms
  alias ExGames.Wire

  setup do
    {:ok, room_id} = Rooms.start(ExGames.Test.Room)
    {:ok, other_id} = Rooms.start(ExGames.Test.Room)
    %{room_id: room_id, other_id: other_id}
  end

  # Процесс теста играет транспорт: прокси мониторят его, их сообщения
  # приходят прямо в почтовый ящик теста и прогоняются через handle_msg/2 —
  # ровно как это делает WebSock-шелл.
  @proxy_msgs [:channel_frame, :channel_closed, :channel_error, :DOWN]

  defp collect(state, quiet_ms \\ 100) do
    receive do
      msg when elem(msg, 0) in @proxy_msgs ->
        {out, state} = Gateway.handle_msg(state, msg)
        {state, frames} = collect(state, quiet_ms)
        {state, out ++ frames}
    after
      quiet_ms ->
        {state, []}
    end
  end

  # ждёт появления кадра, удовлетворяющего предикату; неподошедшие кадры
  # возвращаются остатком — их можно передать следующему wait_frame
  defp wait_frame(state, pred, tries \\ 50, acc \\ []) do
    case Enum.find(acc, pred) do
      nil when tries <= 0 ->
        raise "frame did not arrive"

      nil ->
        {state, frames} = collect(state)
        wait_frame(state, pred, tries - 1, acc ++ frames)

      frame ->
        {state, frame, List.delete(acc, frame)}
    end
  end

  defp unwrap_mux(frame) do
    assert {:ok, {:mux, room_id, inner}} = Wire.decode(frame)
    {room_id, inner}
  end

  test "enter открывает канал: join_room приходит в mux-конверте", %{room_id: room_id} do
    sid = ExGames.Id.session_id()
    :ok = Server.reserve_seat(room_id, sid, %{}, %{})

    state = Gateway.new()
    {:ok, state} = Gateway.enter(state, room_id, sid)

    {state, frame, _rest} =
      wait_frame(state, &match?({:ok, {:mux, ^room_id, _}}, Wire.decode(&1)))

    {^room_id, join_inner} = unwrap_mux(frame)

    assert {:ok, {:join_room, %{"session_id" => ^sid, "reconnection_token" => token}}} =
             Wire.decode(join_inner)

    assert is_binary(token)
    assert Gateway.channel_ids(state) == [room_id]
  end

  test "route доставляет внутренний кадр в комнату, ответ помечен комнатой", %{
    room_id: room_id
  } do
    sid = ExGames.Id.session_id()
    :ok = Server.reserve_seat(room_id, sid, %{}, %{})

    state = Gateway.new()
    {:ok, state} = Gateway.enter(state, room_id, sid)
    {state, _, _} = wait_frame(state, &match?({:ok, {:mux, ^room_id, _}}, Wire.decode(&1)))

    :ok = Gateway.route(state, room_id, Wire.encode(:room_data, {"echo", %{"x" => 1}}))

    {state, frame, _rest} =
      wait_frame(state, fn frame ->
        case Wire.decode(frame) do
          {:ok, {:mux, ^room_id, inner}} ->
            match?({:ok, {:room_data, _, _}}, Wire.decode(inner))

          _ ->
            false
        end
      end)

    {^room_id, inner} = unwrap_mux(frame)
    assert {:ok, {:room_data, "echo", %{"x" => 1}}} = Wire.decode(inner)
  end

  test "две комнаты на одном gateway: кадры размечены своими room_id", %{
    room_id: room_id,
    other_id: other_id
  } do
    sid1 = ExGames.Id.session_id()
    sid2 = ExGames.Id.session_id()
    :ok = Server.reserve_seat(room_id, sid1, %{}, %{})
    :ok = Server.reserve_seat(other_id, sid2, %{}, %{})

    state = Gateway.new()
    {:ok, state} = Gateway.enter(state, room_id, sid1)
    {:ok, state} = Gateway.enter(state, other_id, sid2)

    {state, frame1, rest} =
      wait_frame(state, &match?({:ok, {:mux, ^room_id, _}}, Wire.decode(&1)))

    {state, frame2, _} =
      wait_frame(state, &match?({:ok, {:mux, ^other_id, _}}, Wire.decode(&1)), 50, rest)

    assert {^room_id, _} = unwrap_mux(frame1)
    assert {^other_id, _} = unwrap_mux(frame2)
    assert Enum.sort(Gateway.channel_ids(state)) == Enum.sort([room_id, other_id])
  end

  test "повторный enter в ту же комнату отклоняется без второго канала", %{room_id: room_id} do
    sid = ExGames.Id.session_id()
    :ok = Server.reserve_seat(room_id, sid, %{}, %{})

    state = Gateway.new()
    {:ok, state} = Gateway.enter(state, room_id, sid)
    assert {:error, :already_entered} = Gateway.enter(state, room_id, "another-session")

    {state, _} = collect(state)
    assert Gateway.channel_ids(state) == [room_id]
  end

  test "wrapнутый leave_room закрывает канал mux_closed, соседний канал жив", %{
    room_id: room_id,
    other_id: other_id
  } do
    sid1 = ExGames.Id.session_id()
    sid2 = ExGames.Id.session_id()
    :ok = Server.reserve_seat(room_id, sid1, %{}, %{})
    :ok = Server.reserve_seat(other_id, sid2, %{}, %{})

    state = Gateway.new()
    {:ok, state} = Gateway.enter(state, room_id, sid1)
    {:ok, state} = Gateway.enter(state, other_id, sid2)
    {state, _} = collect(state)

    :ok = Gateway.route(state, room_id, Wire.encode(:leave_room))

    {state, frame, _rest} =
      wait_frame(state, &match?({:ok, {:mux_closed, ^room_id, _, _}}, Wire.decode(&1)))

    assert {:ok, {:mux_closed, ^room_id, 4000, "client left"}} = Wire.decode(frame)
    assert Gateway.channel_ids(state) == [other_id]
  end

  test "enter без брони закрывает канал ошибкой 522", %{room_id: room_id} do
    state = Gateway.new()
    {:ok, state} = Gateway.enter(state, room_id, "ghost")

    {state, frame, _rest} =
      wait_frame(state, &match?({:ok, {:mux_closed, _, _, _}}, Wire.decode(&1)))

    assert {:ok, {:mux_closed, ^room_id, 522, "enter failed: no_reservation"}} =
             Wire.decode(frame)

    assert Gateway.channel_ids(state) == []
  end

  test "enter в несуществующую комнату закрывает канал ошибкой 521", %{room_id: room_id} do
    state = Gateway.new()
    {:ok, state} = Gateway.enter(state, "nowhere", "ghost")

    {state, frame, _rest} =
      wait_frame(state, &match?({:ok, {:mux_closed, _, _, _}}, Wire.decode(&1)))

    assert {:ok, {:mux_closed, "nowhere", 521, "enter failed: unknown_room"}} =
             Wire.decode(frame)

    assert Gateway.channel_ids(state) == []
  end

  test "смерть транспорта уводит сессию в reconnect-слот; повторный вход по токену делает reattach",
       %{room_id: room_id} do
    sid = ExGames.Id.session_id()
    :ok = Server.reserve_seat(room_id, sid, %{}, %{})

    # отдельный процесс-транспорт, чтобы убить его, не тронув тест
    shell = spawn(fn -> shell_start(room_id, sid) end)

    token =
      wait_until(fn ->
        shell
        |> shell_frames()
        |> Enum.find_value(fn frame ->
          case Wire.decode(frame) do
            {:ok, {:mux, ^room_id, inner}} ->
              case Wire.decode(inner) do
                {:ok, {:join_room, %{"reconnection_token" => token}}} -> token
                _ -> nil
              end

            _ ->
              nil
          end
        end)
      end)

    # транспорт умер (kill): прокси выходят по монитору, комната видит DOWN
    Process.exit(shell, :kill)

    wait_until(fn ->
      case Server.reconnect(room_id, sid, token) do
        {:ok, ^sid} -> true
        _ -> nil
      end
    end)

    # повторный вход уже по токену (reattach): join_room с ротированным токеном
    state = Gateway.new()
    {:ok, state} = Gateway.enter(state, room_id, sid, token)

    {state, frame, _rest} =
      wait_frame(state, &match?({:ok, {:mux, ^room_id, _}}, Wire.decode(&1)))

    {^room_id, join_inner} = unwrap_mux(frame)

    assert {:ok, {:join_room, %{"reconnection_token" => new_token}}} = Wire.decode(join_inner)
    assert new_token != token
    assert Gateway.channel_ids(state) == [room_id]
  end

  # минимальный живой шелл: держит состояние gateway и копит сетевые кадры
  defp shell_start(room_id, sid) do
    {:ok, state} = Gateway.enter(Gateway.new(), room_id, sid)
    shell_idle(state, [])
  end

  defp shell_idle(state, frames) do
    receive do
      {:shell_frames, from, ref} ->
        send(from, {ref, Enum.reverse(frames)})
        shell_idle(state, frames)

      :shell_stop ->
        :ok

      msg ->
        {out, state} = Gateway.handle_msg(state, msg)
        shell_idle(state, frames ++ out)
    end
  end

  defp shell_frames(shell) do
    ref = make_ref()
    send(shell, {:shell_frames, self(), ref})

    receive do
      {^ref, frames} -> frames
    after
      100 -> []
    end
  end

  defp wait_until(fun, tries \\ 50) do
    case fun.() do
      nil ->
        if tries == 0, do: raise("condition did not hold")
        Process.sleep(20)
        wait_until(fun, tries - 1)

      value ->
        value
    end
  end
end
