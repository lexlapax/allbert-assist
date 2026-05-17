defmodule StockSage.Actions.RunAnalysisTest do
  use StockSage.DataCase, async: false

  import ExUnit.CaptureLog

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

      # force_stub: true so the bridge uses the deterministic stub path
      # (the test environment doesn't have TradingAgents installed). The
      # persisted detail row carries `payload.stub == true` for operator
      # visibility.
      params = %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        user_id: "alice",
        force_stub: true
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
        queue_entry_id: entry.id,
        force_stub: true
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

    test "queue_entry_id not found returns :queue_entry_not_found and writes NO analysis row" do
      # v0.22 audit closeout (gap 3): before the fix, an invalid queue_entry_id
      # silently no-opped in update_queue/5 but the bridge was already called
      # and the analysis row already persisted, polluting the test DB.
      context = %{confirmation: %{approved?: true, id: "test-confirmation"}}

      params = %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        user_id: "alice",
        queue_entry_id: "queue_missing_xyz",
        force_stub: true
      }

      pre_count = length(Analyses.list_analyses("alice", limit: 100))

      assert {:ok, response} = Runner.run("run_analysis", params, context)
      assert response.status == :error
      assert response.error == :queue_entry_not_found

      post_count = length(Analyses.list_analyses("alice", limit: 100))

      assert post_count == pre_count,
             "no analysis row should have been persisted for a missing queue id; " <>
               "pre=#{pre_count} post=#{post_count}"
    end

    test "queue_entry_id from another user returns :queue_entry_not_found (cross-user isolation)" do
      # The queue entry belongs to alice; bob tries to consume it. Behavior is
      # identical to a missing entry — no leak of alice's data, no row written.
      {:ok, alice_entry} =
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
        user_id: "bob",
        queue_entry_id: alice_entry.id,
        force_stub: true
      }

      assert {:ok, response} = Runner.run("run_analysis", params, context)
      assert response.status == :error
      assert response.error == :queue_entry_not_found

      assert Analyses.list_analyses("bob", limit: 100) == [],
             "bob should not have any analysis rows from a cross-user queue id"
    end

    test "queue_entry_id already-consumed returns :queue_entry_not_found" do
      {:ok, entry} =
        Queue.create_entry(%{
          user_id: "alice",
          symbol: "MSFT",
          status: "queued",
          priority: "normal"
        })

      # Pre-consume the entry.
      {:ok, _consumed} = Queue.update_entry_status(entry, "completed")

      context = %{confirmation: %{approved?: true, id: "test-confirmation"}}

      params = %{
        ticker: "MSFT",
        analysis_date: "2026-05-01",
        user_id: "alice",
        queue_entry_id: entry.id,
        force_stub: true
      }

      assert {:ok, response} = Runner.run("run_analysis", params, context)
      assert response.status == :error
      assert response.error == :queue_entry_not_found
      assert response.detail =~ "already consumed"
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

  describe "named StockSage signals (v0.22 audit closeout — gap 4)" do
    setup do
      original_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original_level) end)
      :ok
    end

    test "fires analysis_requested and analysis_completed on the happy path" do
      context = %{confirmation: %{approved?: true, id: "test-confirmation"}}

      params = %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        user_id: "alice",
        force_stub: true
      }

      log =
        capture_log([level: :info], fn ->
          assert {:ok, response} = Runner.run("run_analysis", params, context)
          assert response.status == :completed
        end)

      assert log =~ "allbert.stocksage.analysis_requested",
             "expected analysis_requested signal in log; got: #{log}"

      assert log =~ "allbert.stocksage.analysis_completed",
             "expected analysis_completed signal in log; got: #{log}"

      refute log =~ "allbert.stocksage.analysis_failed",
             "analysis_failed must not fire on the happy path"
    end

    test "fires analysis_failed when queue validation rejects before bridge call" do
      context = %{confirmation: %{approved?: true, id: "test-confirmation"}}

      params = %{
        ticker: "AAPL",
        analysis_date: "2026-05-01",
        user_id: "alice",
        queue_entry_id: "queue_missing",
        force_stub: true
      }

      log =
        capture_log([level: :info], fn ->
          assert {:ok, response} = Runner.run("run_analysis", params, context)
          assert response.error == :queue_entry_not_found
        end)

      assert log =~ "allbert.stocksage.analysis_failed",
             "expected analysis_failed signal for queue-validation rejection"

      refute log =~ "allbert.stocksage.analysis_requested",
             "analysis_requested must not fire when queue validation rejects first"
    end
  end

  describe "approve_confirmation end-to-end" do
    test "approving a pending run_analysis confirmation persists the result" do
      # force_stub is persisted into the confirmation's resume_params_ref
      # so the resumed action also runs in stub mode (no silent
      # stub-mode flip at approval time).
      params = %{
        ticker: "MSFT",
        analysis_date: "2026-05-01",
        user_id: "alice",
        force_stub: true
      }

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
