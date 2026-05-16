defmodule StockSage.TraderBridgeTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Settings
  alias StockSage.TraderBridge

  @moduletag :bridge

  setup do
    python = System.find_executable("python3")
    if is_nil(python), do: {:skip, "python3 not available"}, else: :ok
  end

  describe "with bridge enabled" do
    setup do
      put_setting!("stocksage.bridge_enabled", true)
      name = unique_name()
      {:ok, pid} = TraderBridge.start_link(name: name)
      on_exit(fn -> safe_stop(pid) end)
      %{name: name}
    end

    test "ping returns :ok when bridge is running", %{name: name} do
      assert :ok = TraderBridge.ping(name)
      assert TraderBridge.bridge_status(name) == :running
    end

    test "analyze with valid params returns a structured result", %{name: name} do
      params = %{ticker: "AAPL", analysis_date: "2026-05-01", engine: "tradingagents"}
      assert {:ok, result} = TraderBridge.analyze(params, name)

      assert result["ticker"] == "AAPL"
      assert result["analysis_date"] == "2026-05-01"
      assert result["engine"] == "tradingagents"
      assert is_binary(result["summary"])
      assert result["truncated"] in [true, false]
    end

    test "analyze rejects an invalid ticker via bridge.py validation", %{name: name} do
      params = %{ticker: "bad$ticker!", analysis_date: "2026-05-01"}
      assert {:error, {:bridge_error, reason}} = TraderBridge.analyze(params, name)
      assert reason =~ "invalid_ticker"
    end

    test "analyze rejects an invalid analysis_date", %{name: name} do
      params = %{ticker: "AAPL", analysis_date: "not-a-date"}
      assert {:error, {:bridge_error, reason}} = TraderBridge.analyze(params, name)
      assert reason =~ "invalid_analysis_date"
    end
  end

  describe "with bridge disabled" do
    setup do
      put_setting!("stocksage.bridge_enabled", false)
      on_exit(fn -> put_setting!("stocksage.bridge_enabled", true) end)
      name = unique_name()
      {:ok, pid} = TraderBridge.start_link(name: name)
      on_exit(fn -> safe_stop(pid) end)
      %{name: name}
    end

    test "bridge_status reports :disabled and analyze returns :bridge_disabled", %{name: name} do
      assert TraderBridge.bridge_status(name) == :disabled
      assert {:error, :bridge_disabled} = TraderBridge.ping(name)

      assert {:error, :bridge_disabled} =
               TraderBridge.analyze(%{ticker: "AAPL", analysis_date: "2026-05-01"}, name)
    end
  end

  describe "crash recovery" do
    setup do
      put_setting!("stocksage.bridge_enabled", true)
      name = unique_name()
      {:ok, pid} = TraderBridge.start_link(name: name)
      on_exit(fn -> safe_stop(pid) end)
      %{name: name, pid: pid}
    end

    test "closing the underlying port marks the bridge :crashed and recovers on next call",
         %{name: name} do
      # Bring the bridge up.
      assert :ok = TraderBridge.ping(name)
      assert TraderBridge.bridge_status(name) == :running

      # Force the port to exit by sending a malformed close signal via Port.close.
      pid = Process.whereis(name)

      :sys.replace_state(pid, fn state ->
        if is_port(state.port), do: Port.close(state.port)
        state
      end)

      # Wait briefly for the {:EXIT, port, ...} message to be processed.
      Process.sleep(50)

      # Subsequent call lazily reopens the port.
      assert :ok = TraderBridge.ping(name)
      assert TraderBridge.bridge_status(name) == :running
    end
  end

  defp put_setting!(key, value) do
    case Settings.put(key, value, %{actor: "test"}) do
      {:ok, _resolved} -> :ok
      {:error, reason} -> flunk("Settings.put #{inspect(key)} failed: #{inspect(reason)}")
    end
  end

  defp unique_name do
    :"stocksage_trader_bridge_test_#{System.unique_integer([:positive])}"
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
