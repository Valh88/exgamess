defmodule ExGames.GameLogicTest do
  use ExUnit.Case, async: false

  alias ExGames.GameLogic.Framing
  alias ExGames.GameLogic.Server

  # -------------------------------------------------------------------------
  # Framing
  # -------------------------------------------------------------------------

  test "framing roundtrip" do
    doc = %{"op" => "call", "args" => [1, -5, "text", nil, %{"nested" => true}]}
    {decoded, rest} = Framing.decode(Framing.encode(doc) |> IO.iodata_to_binary())
    assert decoded == doc
    assert rest == <<>>
  end

  test "framing incomplete buffer" do
    assert :incomplete = Framing.decode(<<>>)
    assert :incomplete = Framing.decode(<<0, 0, 0, 5, 1>>)
  end

  # -------------------------------------------------------------------------
  # Elixir adapter (in-process)
  # -------------------------------------------------------------------------

  describe "Elixir adapter" do
    defmodule Rules do
      @moduledoc false
      def init(_args), do: %{score: 0, ticks: 0}

      def call(state, "add", [amount]),
        do: {:ok, state.score + amount, Map.update!(state, :score, &(&1 + amount))}

      def call(_state, "fail", _args), do: {:error, :boom}
      def tick(state, dt), do: {:ok, Map.update!(state, :ticks, &(&1 + dt))}
    end

    test "init/call/tick via GameLogic.Server" do
      id = "logic_#{System.unique_integer([:positive])}"

      {:ok, _} =
        DynamicSupervisor.start_child(
          ExGames.LogicSupervisor,
          {Server, id: id, adapter: ExGames.GameLogic.Adapters.Elixir, module: Rules}
        )

      assert {:ok, 7} = Server.call(id, "add", [7])

      assert {:ok, %{score: 7, ticks: 0}} = Server.state(id)

      # симулируем тики: dt копится в :ticks
      {:ok, pid} = Server.lookup(id)
      send(pid, :tick)
      Process.sleep(5)
      send(pid, :tick)
      _ = :sys.get_state(pid)

      assert {:ok, %{ticks: ticks}} = Server.state(id)
      assert ticks > 0

      assert {:error, :boom} = Server.call(id, "fail", [])

      :ok = Server.stop(id)
    end
  end

  # -------------------------------------------------------------------------
  # Port adapter с echo-escript (нативный протокол по stdio)
  # -------------------------------------------------------------------------

  describe "Port adapter" do
    @escript Path.expand("priv/native_echo.exs", __DIR__ |> Path.dirname() |> Path.dirname())

    @tag :native
    test "native echo through stdio" do
      # Запускается явно: mix test --include native. Пропускается по умолчанию:
      # Windows-специфика spawn'а нативных процессов проверяется отдельно,
      # полноценный тест нативного пути — при написании Haxe SDK
      # (нативный msgpack-клиент). Framing-протокол покрыт тестами выше.
      id = "logicp_#{System.unique_integer([:positive])}"

      {:ok, _} =
        DynamicSupervisor.start_child(
          ExGames.LogicSupervisor,
          {Server,
           id: id,
           adapter: ExGames.GameLogic.Adapters.Port,
           command: {elixir_bin(), ["--no-halt", @escript]},
           init_timeout: 15_000}
        )

      assert {:ok, %{score: 0, tick: 0}} = Server.state(id)

      assert {:ok, _result, %{score: 5}} = Server.call(id, "add_score", [5])
      {:ok, pid} = Server.lookup(id)
      send(pid, :tick)
      _ = :sys.get_state(pid)

      assert {:ok, %{tick: dt}} = Server.state(id)
      assert dt >= 0

      Server.stop(id)
    end
  end

  defp elixir_bin do
    case :os.type() do
      {:win32, _} -> "elixir.bat"
      _ -> "elixir"
    end
  end
end
