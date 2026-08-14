defmodule AllbertAssist.DevGates.V13ZeroShotEvalTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.DevGates.V13ZeroShotEval
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Projection
  alias AllbertAssist.Memory.Proposals.Proposal
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody

  defmodule ReplacingReadiness do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

    def init(:ok), do: {:ok, %{calls: 0, e1: barrier(), e2: barrier()}}

    def handle_call(:status, _from, state) do
      pid = if state.calls == 0, do: state.e1, else: state.e2

      status = %{
        phase: :ready,
        barrier_pid: pid,
        snapshot_digest: String.duplicate("a", 64),
        expected_ids: [],
        subscribed_ids: [],
        acked_ids: [],
        diagnostics: []
      }

      {:reply, {:ok, status}, %{state | calls: state.calls + 1}}
    end

    def terminate(_reason, state),
      do:
        (
          Process.exit(state.e1, :kill)
          Process.exit(state.e2, :kill)
        )

    defp barrier, do: spawn(fn -> Process.sleep(:infinity) end)
  end

  @fixture Path.expand("../../fixtures/v1.3/memory_zero_shot.json", __DIR__)

  defmodule DeterministicAnswerer do
    def answer(text, %{active_memory: chunks}) do
      message =
        cond do
          String.contains?(text, "private observatory") -> "UNKNOWN"
          String.contains?(text, "travel seat") -> "UNKNOWN"
          String.contains?(text, "retired launch codename") -> "UNKNOWN"
          chunks == [] -> "UNKNOWN"
          true -> chunks |> hd() |> Map.fetch!(:body)
        end

      prompt_bytes =
        byte_size(text) + Enum.sum(Enum.map(chunks, &byte_size(Map.get(&1, :body, ""))))

      {:ok,
       %{
         message: message,
         diagnostic: %{status: :used, usage: %{input_tokens: div(prompt_bytes, 4) + 1}}
       }}
    end
  end

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_memory = Application.get_env(:allbert_assist, Memory)
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_direct_answer = Application.get_env(:allbert_assist, DirectAnswer)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-v13-zero-shot-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Memory)
    Application.delete_env(:allbert_assist, Settings)
    Application.put_env(:allbert_assist, DirectAnswer, answerer: DeterministicAnswerer)
    KeyCustody.invalidate(:all)
    {:ok, projection} = Projection.start_link(root: Paths.memory_projection_root(), name: nil)

    on_exit(fn ->
      if Process.alive?(projection), do: GenServer.stop(projection)
      KeyCustody.invalidate(:all)
      restore_home(original_home)
      restore_env(Paths, original_paths)
      restore_env(Memory, original_memory)
      restore_env(Settings, original_settings)
      restore_env(DirectAnswer, original_direct_answer)
      File.rm_rf!(home)
    end)

    {:ok, projection: projection}
  end

  test "seeded corpus proves zero-shot uplift, negative abstention, and token deltas", %{
    projection: projection
  } do
    fixture = V13ZeroShotEval.load_fixture!(@fixture)
    rows = fixture["rows"]

    assert Enum.count(rows, &(&1["kind"] == "positive")) == 6
    assert Enum.map(rows, & &1["kind"]) |> Enum.take(-3) == ~w[absent proposed superseded]

    assert :ok = V13ZeroShotEval.seed_fixture!(fixture)
    assert %Proposal{status: "pending"} = Repo.get!(Proposal, "proposal-zero-shot-seat")

    assert {:ok, current} =
             Claims.current("019fb383-4a88-7000-8000-000000000017")

    assert current["payload"]["value"] =~ "silver-current-882"
    refute current["payload"]["value"] =~ "ember-archive-419"
    assert {:ok, _build} = Projection.rebuild(projection)

    result =
      V13ZeroShotEval.evaluate!(fixture,
        profile: "direct_answer_local",
        projection: projection,
        replay_answerer: DeterministicAnswerer
      )

    assert result.status == "passed", inspect(result)
    assert result.stats.baseline_positive_correct == 0
    assert result.stats.memory_positive_correct == 6
    assert result.stats.zero_shot_uplift == 1.0
    assert result.stats.memory_negative_abstained == 3
    assert result.stats.memory_abstention_rate == 1.0
    assert result.stats.baseline_interactions_required == 12
    assert result.stats.memory_interactions_required == 6
    assert result.stats.token_usage_complete
    assert result.stats.memory_overhead_tokens > 0
    assert result.stats.compact_vs_source_replay_savings_tokens > 0
  end

  test "same-digest replacement stops zero-shot before any provider row", %{
    projection: projection
  } do
    original = Process.whereis(AllbertAssist.Pack.Readiness)
    true = Process.unregister(AllbertAssist.Pack.Readiness)
    {:ok, replacement} = ReplacingReadiness.start_link(name: AllbertAssist.Pack.Readiness)

    on_exit(fn ->
      if Process.whereis(AllbertAssist.Pack.Readiness) == replacement,
        do: Process.unregister(AllbertAssist.Pack.Readiness)

      if Process.alive?(replacement), do: GenServer.stop(replacement)

      if Process.alive?(original) and is_nil(Process.whereis(AllbertAssist.Pack.Readiness)),
        do: Process.register(original, AllbertAssist.Pack.Readiness)
    end)

    fixture = V13ZeroShotEval.load_fixture!(@fixture)

    assert_raise RuntimeError, ~r/product is not ready/, fn ->
      V13ZeroShotEval.evaluate!(fixture,
        projection: projection,
        replay_answerer: fn _text, _context ->
          send(self(), :provider_called)
          {:ok, %{}}
        end
      )
    end

    refute_received :provider_called
  end

  defp restore_home(nil), do: System.delete_env("ALLBERT_HOME")
  defp restore_home(value), do: System.put_env("ALLBERT_HOME", value)
  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
