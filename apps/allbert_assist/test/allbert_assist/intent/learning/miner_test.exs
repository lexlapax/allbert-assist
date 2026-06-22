defmodule AllbertAssist.Intent.Learning.MinerTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Intent.Learning.Miner
  alias AllbertAssist.Intent.Router.{DescriptorResolver, DescriptorStore}
  alias AllbertAssist.Paths

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_home_dir = System.get_env("ALLBERT_HOME_DIR")
    original_paths = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(System.tmp_dir!(), "allbert-intent-miner-#{System.unique_integer([:positive])}")

    System.put_env("ALLBERT_HOME", home)
    System.delete_env("ALLBERT_HOME_DIR")
    Application.delete_env(:allbert_assist, Paths)

    on_exit(fn ->
      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      if original_home_dir,
        do: System.put_env("ALLBERT_HOME_DIR", original_home_dir),
        else: System.delete_env("ALLBERT_HOME_DIR")

      if original_paths,
        do: Application.put_env(:allbert_assist, Paths, original_paths),
        else: Application.delete_env(:allbert_assist, Paths)

      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "mines redacted evidence into an inert learned-review descriptor proposal" do
    assert [%{action_name: "append_memory", support_count: 1} = proposal] =
             Miner.mine(%{
               source: :clarification,
               action_name: "append_memory",
               utterance: "remember release review preference api key sk-test-secret",
               confidence: 0.72,
               evidence_ref: %{trace_id: "tr_1", api_key: "sk-test-secret"}
             })

    assert proposal.app_id == :allbert
    assert proposal.confidence == 0.72
    assert [example] = proposal.examples
    assert example =~ "[REDACTED"
    refute example =~ "sk-test-secret"

    assert {:ok, path} = DescriptorStore.path(:review, :allbert, "append_memory")
    yaml = File.read!(path)
    assert yaml =~ "action_name: append_memory"
    assert yaml =~ "support_count: 1"
    refute yaml =~ "sk-test-secret"

    refute DescriptorResolver.resolve()
           |> Enum.any?(&(&1.action_name == "append_memory" and &1.source == :review))
  end

  test "merges repeated evidence into one proposal with support count and evidence refs" do
    Miner.mine(%{
      source: :trace,
      action_name: "append_memory",
      utterance: "remember the release checklist format",
      confidence: 0.4,
      evidence_ref: %{trace_id: "tr_1"}
    })

    assert [%{support_count: 2, confidence: 0.8} = proposal] =
             Miner.mine(%{
               source: :confirmation,
               action_name: "append_memory",
               utterance: "remember the release checklist format",
               confidence: 0.8,
               evidence_ref: %{confirmation_id: "conf_1"}
             })

    assert length(proposal.examples) == 1
    assert length(proposal.evidence_refs) == 2

    assert {:ok, review} = Runner.run("intent_list_review", %{}, context())

    assert [%{action_name: "append_memory", support_count: 2, evidence_count: 2}] =
             review.proposals

    assert review.message =~ "append_memory app_id=allbert support=2"
  end

  test "skips internal or unknown actions" do
    assert [] =
             Miner.mine([
               %{action_name: "intent_doctor", utterance: "operator run intent doctor"},
               %{action_name: "missing_action", utterance: "do missing action"}
             ])

    assert DescriptorStore.read_attrs(:review) == []
  end

  defp context do
    %{
      actor: "local",
      operator_id: "local",
      channel: :test,
      request: %{operator_id: "local", channel: :test}
    }
  end
end
