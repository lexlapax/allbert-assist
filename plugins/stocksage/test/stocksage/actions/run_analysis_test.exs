defmodule StockSage.Actions.RunAnalysisTest do
  use StockSage.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Settings
  alias StockSage.Analyses
  alias StockSage.Queue
  alias StockSage.TraderBridge

  @moduletag :bridge

  setup do
    python = System.find_executable("python3")
    if is_nil(python), do: {:skip, "python3 not available"}, else: :ok
  end

  setup do
    put_setting!("stocksage.bridge_enabled", true)
    put_setting!("permissions.stocksage_analyze", "needs_confirmation")
    # The plugin supervisor already starts a StockSage.TraderBridge at app
    # boot; if it isn't running (some env disabled it), start one ad-hoc.
    case Process.whereis(StockSage.TraderBridge) do
      nil ->
        {:ok, pid} = TraderBridge.start_link(name: StockSage.TraderBridge)
        on_exit(fn -> safe_stop(pid) end)

      _pid ->
        :ok
    end

    %{}
  end

  describe "initial call" do
    test "creates a confirmation record and returns :needs_confirmation" do
      params = %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        user_id: "alice"
      }

      assert {:ok, response} = Runner.run("run_analysis", params, %{})
      assert response.status == :needs_confirmation
      assert is_binary(response.confirmation_id)

      {:ok, record} = Confirmations.read(response.confirmation_id)
      assert record["status"] == "pending"
      assert record["target_permission"] == "stocksage_analyze"
      assert record["params_summary"]["ticker"] == "AAPL"
      assert record["params_summary"]["analysis_date"] == "2026-05-01"
      assert record["params_summary"]["disclosure"] =~ "TradingAgents"
    end

    test "rejects invalid ticker before creating a confirmation" do
      assert {:ok, response} =
               Runner.run(
                 "run_analysis",
                 %{ticker: "bad ticker!", analysis_date: "2026-05-01", user_id: "alice"},
                 %{}
               )

      assert response.status == :error
      assert response.error == :invalid_ticker
      refute Map.has_key?(response, :confirmation_id)
    end

    test "rejects invalid analysis_date" do
      assert {:ok, response} =
               Runner.run(
                 "run_analysis",
                 %{ticker: "AAPL", analysis_date: "tomorrow", user_id: "alice"},
                 %{}
               )

      assert response.status == :error
      assert response.error == :invalid_analysis_date
    end

    test "returns :bridge_disabled when bridge_enabled is false" do
      put_setting!("stocksage.bridge_enabled", false)

      assert {:ok, response} =
               Runner.run(
                 "run_analysis",
                 %{ticker: "AAPL", analysis_date: "2026-05-01", user_id: "alice"},
                 %{}
               )

      assert response.status == :error
      assert response.error == :bridge_disabled

      # Ensure no confirmation record was created.
      refute Map.has_key?(response, :confirmation_id)
    end
  end

  describe "approved resume" do
    test "executes the bridge and persists a completed analysis row" do
      context = %{confirmation: %{approved?: true, id: "test-confirmation"}}

      params = %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        user_id: "alice"
      }

      assert {:ok, response} = Runner.run("run_analysis", params, context)

      assert response.status == :completed
      assert response.ticker == "AAPL"
      assert is_binary(response.analysis_id)
      assert response.bridge_duration_ms >= 0

      analyses = Analyses.list_analyses("alice", limit: 10)
      assert Enum.any?(analyses, &(&1.id == response.analysis_id))
      assert Enum.any?(analyses, &(&1.status == "completed" and &1.source == "python_bridge"))
    end

    test "links to a queue entry when queue_entry_id is provided" do
      {:ok, entry} =
        Queue.create_entry(%{
          user_id: "alice",
          symbol: "TSLA",
          status: "queued",
          priority: "normal"
        })

      context = %{confirmation: %{approved?: true, id: "test-confirmation"}}

      params = %{
        ticker: "TSLA",
        analysis_date: "2026-05-01",
        user_id: "alice",
        queue_entry_id: entry.id
      }

      assert {:ok, response} = Runner.run("run_analysis", params, context)
      assert response.status == :completed

      {:ok, refreshed} = Queue.get_entry("alice", entry.id)
      assert refreshed.status == "completed"

      runs = Queue.list_runs("alice", entry.id)

      assert Enum.any?(
               runs,
               &(&1.status == "completed" and &1.analysis_id == response.analysis_id)
             )
    end

    test "writes a failed row when the bridge returns an error" do
      context = %{confirmation: %{approved?: true, id: "test-confirmation"}}

      # The bridge rejects bad tickers before they reach TradingAgents — but our
      # Elixir-side validation also rejects them, so failure is exercised via a
      # confirmation resume with a forced bad params_ref (simulate downstream
      # crash by using an extremely unrealistic ticker shape that escapes Elixir
      # validation; instead use a real ticker and corrupt the engine).
      params = %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        engine: "tradingagents",
        user_id: "alice"
      }

      # Override engine in-flight to trigger bridge error path.
      {:ok, _response} = Runner.run("run_analysis", Map.put(params, :engine, "nope"), context)

      analyses = Analyses.list_analyses("alice", limit: 10)
      assert Enum.any?(analyses, &(&1.status == "failed"))
    end
  end

  defp put_setting!(key, value) do
    case Settings.put(key, value, %{actor: "test"}) do
      {:ok, _resolved} -> :ok
      {:error, reason} -> flunk("Settings.put #{inspect(key)} failed: #{inspect(reason)}")
    end
  end

  describe "approve_confirmation end-to-end" do
    test "approving a pending run_analysis confirmation persists the result" do
      params = %{ticker: "MSFT", analysis_date: "2026-05-01", user_id: "alice"}
      {:ok, response} = Runner.run("run_analysis", params, %{})
      assert response.status == :needs_confirmation
      confirmation_id = response.confirmation_id

      assert {:ok, approval} =
               Runner.run(
                 "approve_confirmation",
                 %{id: confirmation_id, reason: "smoke test"},
                 %{actor: "alice", channel: :test, surface: "action"}
               )

      assert approval.status == :completed, "approval: #{inspect(approval, limit: :infinity)}"

      cm =
        approval.actions
        |> List.first()
        |> Map.get(:confirmation_metadata, %{})

      assert Map.get(cm, :target_resumed?) == true,
             "resume metadata missing or false: #{inspect(cm)}"

      analyses = Analyses.list_analyses("alice", limit: 10)
      assert Enum.any?(analyses, &(&1.symbol == "MSFT" and &1.status == "completed"))
    end
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
