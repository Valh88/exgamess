defmodule ExGames.TelemetryTest do
  @moduledoc """
  Агрегатор доменных метрик: счётчики/gauge'и из событий, сэмплер ноды,
  Prometheus-текст. :telemetry диспетчеризует по полным именам — механика
  обработчика проверяется и напрямую, и через реальные события комнаты.
  """

  use ExUnit.Case, async: false

  defmodule ProbeRoom do
    use ExGames.Room, max_clients: 2

    @impl true
    def room_init(_options, _room), do: {:ok, nil}
  end

  test "обработчик: счётчик события + gauge по числовым измерениям" do
    # реальные события (в списке подписки агрегатора)
    :telemetry.execute([:ex_games, :room, :ping], %{rtt: 33}, %{room_id: "x"})
    :telemetry.execute([:ex_games, :room, :ping], %{rtt: 44}, %{room_id: "x"})

    snap = ExGames.Telemetry.snapshot()
    assert snap.counters["room.ping"] >= 2

    # обработчик синхронен — последнее значение детерминировано
    assert snap.gauges["room.ping.rtt"] == 44

    # нечисловое измерение молча пропускается
    :telemetry.execute([:ex_games, :room, :ping], %{rtt: nil}, %{room_id: "x"})
    assert ExGames.Telemetry.snapshot().gauges["room.ping.rtt"] == 44
  end

  test "обработчик напрямую: событие вне списка подписки тоже агрегируется" do
    ExGames.Telemetry.handle_event([:ex_games, :probe_evt], %{count: 1, rtt_ms: 7}, %{}, nil)

    snap = ExGames.Telemetry.snapshot()
    assert snap.counters["probe_evt"] == 1
    assert snap.gauges["probe_evt.rtt_ms"] == 7
  end

  test "прометей-текст: счётчики с _total, gauge'и без" do
    :telemetry.execute([:ex_games, :room, :kick], %{count: 1}, %{room_id: "x"})
    ExGames.Telemetry.handle_event([:ex_games, :probe_gauge], %{level: 7.5}, %{}, nil)

    text = ExGames.Telemetry.prometheus()

    assert text =~ ~r/# TYPE ex_games_room_kick_total counter\nex_games_room_kick_total \d+\n/
    assert text =~ "# TYPE ex_games_probe_gauge_level gauge\nex_games_probe_gauge_level 7.5\n"
  end

  test "сэмплер ноды пишет gauge'и и возвращает их же" do
    gauges = ExGames.Telemetry.sample()

    assert gauges["node.process_count"] > 0
    assert gauges["node.memory_bytes"] > 0
    assert is_integer(gauges["node.rooms_active"])
    assert Map.has_key?(gauges, "node.clients_in_rooms")
    assert Map.has_key?(gauges, "node.online")

    assert ExGames.Telemetry.snapshot().gauges["node.process_count"] > 0
  end

  test "события комнаты и правда доходят до агрегатора" do
    {:ok, room_id} = ExGames.Rooms.start(ProbeRoom)
    on_exit(fn -> ExGames.Rooms.stop(room_id) end)

    assert ExGames.Telemetry.snapshot().counters["room.created"] >= 1

    ExGames.Telemetry.sample()
    assert ExGames.Telemetry.snapshot().gauges["node.rooms_active"] >= 1
  end
end
