defmodule Mix.Tasks.Stocksage.AgentsTest do
  use StockSage.DataCase

  import ExUnit.CaptureIO

  alias AllbertAssist.Objectives
  alias Mix.Tasks.Stocksage.Agents, as: AgentsTask

  defmodule RotatingReadiness do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

    def rotate, do: GenServer.call(AllbertAssist.Pack.Readiness, :rotate)

    def init(:ok) do
      e1 = spawn(fn -> Process.sleep(:infinity) end)
      e2 = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, %{barrier: e1, barriers: [e1, e2], replacement: e2}}
    end

    def handle_call(:status, _from, state) do
      {:reply,
       {:ok,
        %{
          phase: :ready,
          barrier_pid: state.barrier,
          snapshot_digest: String.duplicate("a", 64),
          expected_ids: [],
          subscribed_ids: [],
          acked_ids: [],
          diagnostics: []
        }}, state}
    end

    def handle_call(:rotate, _from, state),
      do: {:reply, :ok, %{state | barrier: state.replacement}}

    def terminate(_reason, state),
      do: Enum.each(state.barriers, &Process.exit(&1, :kill))
  end

  setup do
    replace_readiness!()
    ensure_agents_supervisor!()
    on_exit(fn -> Mix.Task.reenable("stocksage.agents") end)
    :ok
  end

  test "lists native specialist agents" do
    output =
      capture_io(fn ->
        assert :ok = AgentsTask.run(["list", "--user", "alice"])
      end)

    assert output =~ "StockSage native agents"
    assert output =~ "stocksage.market_context"
    assert output =~ "prompt_version=v0.25.0"
  end

  test "shows one native specialist agent" do
    output =
      capture_io(fn ->
        assert :ok = AgentsTask.run(["show", "stocksage.market_context", "--user", "alice"])
      end)

    assert output =~ "StockSage native agent stocksage.market_context"
    assert output =~ "Role: market_context"
    assert output =~ "Prompt path:"
  end

  test "show reports unknown agent ids" do
    assert_raise Mix.Error, ~r/not found/, fn ->
      capture_io(fn ->
        AgentsTask.run(["show", "stocksage.nope", "--user", "alice"])
      end)
    end
  end

  test "smoke delegates through objective action boundary and fixture evidence" do
    output =
      capture_io(fn ->
        assert :ok =
                 AgentsTask.run([
                   "smoke",
                   "stocksage.market_context",
                   "--ticker",
                   "AAPL",
                   "--analysis-date",
                   "2026-05-15",
                   "--fixture",
                   "--user",
                   "alice"
                 ])
      end)

    assert output =~ "StockSage native agent smoke stocksage.market_context"
    assert output =~ "Evidence packets: 1"
    assert output =~ "stocksage_fetch_market_data"
    assert output =~ "mode=fixture"
  end

  test "same-digest rotation after smoke step write prevents objective finalization" do
    previous = Application.get_env(:stocksage, AgentsTask)

    Application.put_env(:stocksage, AgentsTask,
      after_smoke_step_update: fn -> RotatingReadiness.rotate() end
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:stocksage, AgentsTask, previous)
      else
        Application.delete_env(:stocksage, AgentsTask)
      end
    end)

    assert_raise RuntimeError, ~r/product is not ready/, fn ->
      capture_io(fn ->
        AgentsTask.run([
          "smoke",
          "stocksage.market_context",
          "--ticker",
          "AAPL",
          "--analysis-date",
          "2026-05-15",
          "--fixture",
          "--user",
          "alice"
        ])
      end)
    end

    objective =
      "alice"
      |> Objectives.list_objectives(limit: 10)
      |> Enum.find(&(&1.source_intent == "mix stocksage.agents smoke"))

    assert objective.status == "open"
    assert [%{status: "completed"}] = Objectives.list_steps(objective.id)
  end

  defp replace_readiness! do
    original = Process.whereis(AllbertAssist.Pack.Readiness)
    true = Process.unregister(AllbertAssist.Pack.Readiness)
    {:ok, replacement} = RotatingReadiness.start_link(name: AllbertAssist.Pack.Readiness)

    on_exit(fn ->
      if Process.whereis(AllbertAssist.Pack.Readiness) == replacement,
        do: Process.unregister(AllbertAssist.Pack.Readiness)

      if Process.alive?(replacement), do: GenServer.stop(replacement)

      if Process.alive?(original) and is_nil(Process.whereis(AllbertAssist.Pack.Readiness)),
        do: Process.register(original, AllbertAssist.Pack.Readiness)
    end)
  end

  defp ensure_agents_supervisor! do
    unless Process.whereis(StockSage.Agents.Supervisor) do
      start_supervised!(StockSage.Agents.Supervisor)
    end
  end
end
