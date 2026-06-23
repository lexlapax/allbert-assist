defmodule AllbertAssist.Actions.Intent.OperatorReadActionsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Intent.Router.DescriptorStore
  alias AllbertAssist.Paths

  @read_actions ~w(
    intent_doctor
    intent_list_descriptors
    intent_show_descriptor
    intent_coverage
    intent_eval_run
    intent_list_review
  )

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_home_dir = System.get_env("ALLBERT_HOME_DIR")
    original_paths = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-intent-read-actions-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    System.delete_env("ALLBERT_HOME_DIR")
    Application.put_env(:allbert_assist, Paths, home: home)

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

  test "operator read actions are registered internal capabilities and never routable" do
    agent_modules = Registry.agent_modules()

    for action_name <- @read_actions do
      assert {:ok, module} = Registry.resolve(action_name)
      assert {:ok, capability} = Registry.capability(action_name)

      assert capability.exposure == :internal
      assert capability.permission == :read_only
      assert capability.confirmation == :not_required
      refute module in agent_modules
    end
  end

  test "descriptor read actions return redacted DTOs" do
    assert {:ok, list} = Runner.run("intent_list_descriptors", %{}, context())
    assert list.status == :completed
    assert list.message =~ "append_memory source=code app_id=allbert"

    assert append_memory = Enum.find(list.descriptors, &(&1.action_name == "append_memory"))
    assert append_memory.examples_count >= 1
    refute Map.has_key?(append_memory, :examples)
    refute Map.has_key?(append_memory, :synonyms)

    assert {:ok, show} =
             Runner.run("intent_show_descriptor", %{action: "append_memory"}, context())

    assert show.status == :completed
    assert show.descriptor.action_name == "append_memory"
    assert show.message =~ "examples: #{append_memory.examples_count}"

    assert {:ok, missing} =
             Runner.run("intent_show_descriptor", %{action: "missing_action"}, context())

    assert missing.status == :not_found
    assert missing.descriptor == nil
  end

  test "coverage and review actions expose operator DTOs without routing authority" do
    {:ok, _path} =
      DescriptorStore.put(:review, %{
        app_id: :allbert,
        action_name: "show_app",
        label: "Show app",
        examples: ["show app"],
        synonyms: ["app details"],
        required_slots: []
      })

    assert {:ok, coverage} = Runner.run("intent_coverage", %{}, context())
    assert coverage.status == :completed
    assert is_integer(coverage.coverage.agent_exposed)
    assert is_list(coverage.coverage.missing)
    assert coverage.coverage.review >= 1
    assert coverage.message =~ "coverage: routable="

    assert {:ok, review} = Runner.run("intent_list_review", %{}, context())
    assert review.status == :completed
    assert [%{action_name: "show_app", app_id: "allbert"}] = review.proposals
    assert review.message =~ "show_app app_id=allbert"
  end

  test "eval run reports the deterministic corpus and current gate truth" do
    assert {:ok, response} = Runner.run("intent_eval_run", %{}, context())

    assert response.status == :completed
    assert response.eval_result.corpus_case_count > 0
    assert response.eval_result.baseline.id == "v056-release-baseline"
    assert response.eval_result.gate.status in [:pass, :fail]
    assert is_list(response.eval_result.score.negative_violations)
    assert response.message =~ "intent eval run total="
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
