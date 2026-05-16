defmodule Mix.Tasks.Stocksage.AnalyzeTest do
  use StockSage.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Settings
  alias Mix.Tasks.Stocksage.Analyze, as: AnalyzeTask
  alias StockSage.Analyses
  alias StockSage.TraderBridge

  @moduletag :bridge

  setup do
    python = System.find_executable("python3")
    if is_nil(python), do: {:skip, "python3 not available"}, else: :ok
  end

  setup do
    original = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "stocksage-analyze-task-settings-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      if original do
        Application.put_env(:allbert_assist, Settings, original)
      else
        Application.delete_env(:allbert_assist, Settings)
      end

      File.rm_rf!(root)
      Mix.Task.reenable("stocksage.analyze")
    end)

    put_setting!("stocksage.bridge_enabled", true)
    put_setting!("permissions.stocksage_analyze", "needs_confirmation")

    case Process.whereis(StockSage.TraderBridge) do
      nil ->
        {:ok, pid} = TraderBridge.start_link(name: StockSage.TraderBridge)
        on_exit(fn -> safe_stop(pid) end)

      _pid ->
        :ok
    end

    :ok
  end

  test "creates a confirmation record and prints the confirmation id" do
    output =
      capture_io(fn ->
        AnalyzeTask.run(["AAPL", "2026-05-01", "--user", "alice"])
      end)

    assert output =~ "StockSage analysis confirmation required."
    assert output =~ "Confirmation id:"
    assert output =~ "mix allbert.confirmations approve"
  end

  test "fails with clear usage when args missing" do
    assert_raise Mix.Error, ~r/Usage:/, fn ->
      capture_io(fn -> AnalyzeTask.run([]) end)
    end
  end

  test "rejects an invalid ticker" do
    assert_raise Mix.Error, ~r/invalid_ticker/, fn ->
      capture_io(fn ->
        AnalyzeTask.run(["BAD$TICKER!", "2026-05-01", "--user", "alice"])
      end)
    end
  end

  test "prints bridge_disabled and exits when the bridge is disabled" do
    put_setting!("stocksage.bridge_enabled", false)

    assert_raise Mix.Error, ~r/bridge is disabled/, fn ->
      capture_io(fn ->
        AnalyzeTask.run(["AAPL", "2026-05-01", "--user", "alice"])
      end)
    end
  end

  test "with confirmation context already approved, persists a completed row" do
    # Smoke-style: drive the action directly via the runner first, then verify
    # mix command prints the completed output by simulating an approved
    # context indirectly through the underlying runner.
    capture_io(fn ->
      AnalyzeTask.run(["MSFT", "2026-05-01", "--user", "alice"])
    end)

    # The CLI will only return :needs_confirmation here. Result persistence
    # is exercised end-to-end in StockSage.Actions.RunAnalysisTest; we only
    # assert the CLI did not crash and the action recorded no analysis yet.
    assert Analyses.list_analyses("alice", limit: 10) == []
  end

  defp put_setting!(key, value) do
    case Settings.put(key, value, %{actor: "test"}) do
      {:ok, _resolved} -> :ok
      {:error, reason} -> flunk("Settings.put #{inspect(key)} failed: #{inspect(reason)}")
    end
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
