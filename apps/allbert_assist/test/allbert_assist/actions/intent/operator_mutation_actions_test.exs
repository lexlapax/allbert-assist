defmodule AllbertAssist.Actions.Intent.OperatorMutationActionsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Intent.Router.DescriptorStore
  alias AllbertAssist.Paths

  @mutation_actions ~w(
    optimize_intent_descriptors
    promote_intent_descriptor
    reindex_intent_descriptors
    edit_intent_descriptor
    disable_intent_descriptor
    enable_intent_descriptor
    intent_eval_baseline
    intent_eval_capture
    intent_eval_add
  )

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_home_dir = System.get_env("ALLBERT_HOME_DIR")
    original_paths = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-intent-mutation-actions-#{System.unique_integer([:positive])}"
      )

    fixture_root =
      Path.join(
        File.cwd!(),
        "tmp/allbert-intent-fixture-#{System.unique_integer([:positive])}"
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
      File.rm_rf!(fixture_root)
    end)

    {:ok, home: home, fixture_root: fixture_root}
  end

  test "operator mutation actions are registered internal capabilities and never routable" do
    agent_modules = Registry.agent_modules()

    for action_name <- @mutation_actions do
      assert {:ok, module} = Registry.resolve(action_name)
      assert {:ok, capability} = Registry.capability(action_name)

      assert capability.exposure == :internal
      assert capability.permission == :settings_write
      assert capability.confirmation == :not_required
      refute module in agent_modules
    end
  end

  test "promote action is gate-backed and leaves failing review descriptors inert" do
    {:ok, _path} =
      DescriptorStore.put(:review, %{
        app_id: :allbert,
        action_name: "show_app",
        label: "Show app",
        examples: ["show app"],
        synonyms: ["app details"],
        required_slots: []
      })

    assert {:ok, promoted} =
             Runner.run(
               "promote_intent_descriptor",
               %{action: "show_app", from: "learned"},
               context()
             )

    assert promoted.status == :completed
    assert promoted.message =~ "promoted show_app ->"

    {:ok, review_path} =
      DescriptorStore.put(:review, %{
        app_id: :allbert,
        action_name: "list_channels",
        label: "List channels",
        examples: ["list my channels"],
        synonyms: ["channels"],
        required_slots: [:channel]
      })

    assert {:ok, rejected} =
             Runner.run("promote_intent_descriptor", %{action: "list_channels"}, context())

    assert rejected.status == :rejected
    assert rejected.message =~ "gate failed"
    assert File.exists?(review_path)

    assert {:ok, generated_path} = DescriptorStore.path(:generated, :allbert, "list_channels")
    refute File.exists?(generated_path)
  end

  test "disable is blocked when removal would regress the committed corpus" do
    assert {:ok, rejected} =
             Runner.run("disable_intent_descriptor", %{action: "append_memory"}, context())

    assert rejected.status == :rejected
    assert rejected.message =~ "gate failed"

    assert {:ok, override_path} = DescriptorStore.path(:overrides, :allbert, "append_memory")
    refute File.exists?(override_path)
  end

  test "eval capture/add/baseline actions write redacted path-safe YAML", %{
    fixture_root: fixture_root
  } do
    assert {:ok, captured} =
             Runner.run(
               "intent_eval_capture",
               %{
                 case: %{
                   id: "captured-secret-001",
                   domain: "captured",
                   surface: "tui",
                   utterance: "operator saw a safe routing miss",
                   context: %{api_key: "sk-test-secret"},
                   expected: %{kind: "none"},
                   negative: false,
                   rationale: "operator reviewed"
                 }
               },
               context()
             )

    assert captured.status == :completed
    assert File.exists?(captured.path)
    captured_yaml = File.read!(captured.path)
    assert captured_yaml =~ "[REDACTED]"
    refute captured_yaml =~ "sk-test-secret"

    assert {:ok, added} =
             Runner.run(
               "intent_eval_add",
               %{id: "captured-secret-001", fixture_root: fixture_root},
               context()
             )

    assert added.status == :completed
    assert added.path == Path.join([fixture_root, "captured", "captured-secret-001.yaml"])
    assert File.exists?(added.path)

    assert {:ok, baseline} =
             Runner.run(
               "intent_eval_baseline",
               %{id: "m10-baseline-test", fixture_root: fixture_root},
               context()
             )

    assert baseline.status == :completed
    assert baseline.path == Path.join(fixture_root, "baseline.yaml")
    assert File.read!(baseline.path) =~ "id: m10-baseline-test"
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
