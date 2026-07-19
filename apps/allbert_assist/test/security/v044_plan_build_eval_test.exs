defmodule AllbertAssist.Security.V044PlanBuildEvalTest do
  use AllbertAssist.DataCase, async: false, lane: :security_eval_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Workflows
  alias AllbertAssist.Workflows.{Loader, Validator}

  @eval_ids [
    "workflow-yaml-unknown-key-001",
    "workflow-yaml-script-deny-001",
    "workflow-yaml-dynamic-action-name-deny-001",
    "workflow-yaml-secret-substitution-deny-001",
    "workflow-yaml-env-substitution-deny-001",
    "workflow-yaml-cycle-reject-001",
    "workflow-yaml-forward-ref-reject-001",
    "plan-preview-not-authority-001",
    "plan-run-start-confirmation-required-001",
    "plan-step-permission-not-downgradable-001",
    "plan-cancel-cooperative-001",
    "subagent-delegation-permission-boundary-001",
    "delegate-agent-authority-boundary-001",
    "workflow-expand-rejects-bad-yaml-001",
    "workflow-step-cap-enforced-001",
    "workflow-param-bytes-cap-enforced-001"
  ]

  defmodule PingCommand do
    use Jido.Action,
      name: "v044_plan_build_eval_ping",
      description: "v0.44 plan/build delegate eval command."

    @impl true
    def run(params, context) do
      {:ok, Map.merge(Map.get(context, :state, %{}), %{last_result: {:ok, params}})}
    end
  end

  defmodule StubAgent do
    use AllbertAssist.JidoBacked,
      name: "v044_plan_build_eval_stub",
      description: "v0.44 plan/build delegate eval agent.",
      signal_routes: [
        {"allbert.plan_build.eval.ping", AllbertAssist.Security.V044PlanBuildEvalTest.PingCommand}
      ]

    @impl true
    def rebuild_state(_opts), do: {:ok, %{last_result: nil}}

    @impl true
    def command_modules, do: [AllbertAssist.Security.V044PlanBuildEvalTest.PingCommand]
  end

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths_config = Application.get_env(:allbert_assist, AllbertAssist.Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-v044-plan-eval-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(home)
    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, AllbertAssist.Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    File.mkdir_p!(Path.join(home, "workflows"))
    copy_fixture!("multi_step", home)
    copy_fixture!("single_step", home)

    on_exit(fn ->
      restore_env("ALLBERT_HOME", original_home)
      restore_app_env(AllbertAssist.Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      AgentRegistry.unregister("plan-build-stub")
      File.rm_rf!(home)
    end)

    {:ok, home: home, context: %{actor: "local", user_id: "local", channel: :cli}}
  end

  test "v0.44 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v044)

    assert Enum.map(rows, & &1.id) == @eval_ids
    assert Enum.all?(rows, &(&1.surface == :plan_build))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "workflow YAML rejection eval rows return structured schema errors", %{home: home} do
    assert_eval!("workflow-yaml-unknown-key-001")
    assert_eval!("workflow-yaml-dynamic-action-name-deny-001")
    assert_eval!("workflow-yaml-secret-substitution-deny-001")
    assert_eval!("workflow-yaml-env-substitution-deny-001")
    assert_eval!("workflow-yaml-cycle-reject-001")
    assert_eval!("workflow-yaml-forward-ref-reject-001")
    assert_eval!("workflow-step-cap-enforced-001")

    for {id, reason} <- %{
          "unknown_key" => :unknown_key,
          "dynamic_action_name" => :dynamic_action_name,
          "secret_substitution" => :secret_substitution_attempt,
          "env_substitution" => :env_substitution_attempt,
          "cycle" => :cycle,
          "forward_ref" => :forward_ref,
          "cap_exceeded" => :cap_exceeded
        } do
      copy_fixture!(id, home)
      assert {:ok, workflow} = Loader.load(id)
      assert {:error, error} = Validator.validate(workflow)
      assert error.reason == reason
      assert is_binary(error.pointer)
    end
  end

  test "script-like keys, malformed YAML, and param byte caps fail closed", %{home: home} do
    assert_eval!("workflow-yaml-script-deny-001")
    assert_eval!("workflow-expand-rejects-bad-yaml-001")
    assert_eval!("workflow-param-bytes-cap-enforced-001")

    write_workflow!(home, "script_deny", """
    id: script_deny
    version: 1
    script: "System.cmd(\\"sh\\", [\\"-c\\", \\"echo nope\\"])"
    steps:
      - id: run
        kind: action
        action: direct_answer
        params:
          text: "No script keys."
    """)

    assert {:ok, workflow} = Loader.load("script_deny")
    assert {:error, error} = Validator.validate(workflow)
    assert error.reason == :unknown_key
    assert error.pointer == "/script"

    write_workflow!(home, "bad_yaml", "id: bad_yaml\nsteps:\n  - id: [")
    assert {:error, error} = Loader.load("bad_yaml")
    assert error.reason == :invalid_yaml
    assert error.pointer == "/"

    assert {:ok, _setting} =
             Settings.put("workflows.max_param_bytes_per_step", 8, %{audit?: false})

    assert {:ok, workflow} = Loader.load("single_step")
    assert {:error, error} = Validator.validate(workflow)
    assert error.reason == :cap_exceeded
    assert error.pointer == "/steps/0/params"
  end

  test "preview is advisory and plan start requires confirmation", %{
    context: context
  } do
    assert_eval!("plan-preview-not-authority-001")
    assert_eval!("plan-run-start-confirmation-required-001")

    assert {:ok, %{status: :advisory} = previewed} =
             Runner.run("preview_plan", %{workflow_id: "multi_step"}, context)

    assert previewed.permission_decision.permission == :read_only
    assert previewed.output_data.preview.workflow_id == "multi_step"
    assert Objectives.list_objectives("local") == []

    assert {:ok, pending} =
             Runner.run("start_plan_run", %{workflow_id: "multi_step"}, context)

    assert pending.status == :needs_confirmation
    assert pending.permission_decision.permission == :workflow_run_start
    assert is_binary(pending.confirmation_id)
    assert Objectives.list_objectives("local") == []

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "eval approval"},
               context
             )

    objective_id = get_in(approved, [:output_data, :objective_id])
    assert is_binary(objective_id)
    assert get_in(approved, [:output_data, :run_status]) == :needs_confirmation

    assert [
             %{status: "completed"},
             %{status: "completed", action_params: summarize_params},
             %{status: "blocked", kind: "ask_user"}
           ] = Objectives.list_steps(objective_id)

    refute Jason.decode!(summarize_params)["text"] =~ "${steps.collect.issues}"
  end

  test "confirmed step floors cannot be downgraded or bypassed by workflow YAML", %{
    context: context,
    home: home
  } do
    assert_eval!("plan-step-permission-not-downgradable-001")

    write_workflow!(home, "confirmed_step", """
    id: confirmed_step
    version: 1
    steps:
      - id: shell
        kind: action
        action: run_shell_command
        confirm: false
        params:
          executable: echo
          args: ["hello"]
          cwd: /tmp
    """)

    assert {:ok, expanded} = Workflows.preview("confirmed_step", %{}, %{user_id: "local"})
    assert [start_gate, step_gate] = expanded.preview.authority_gates
    assert start_gate.gate == :workflow_run_start
    assert step_gate.gate == :command_execute

    assert [step] = expanded.preview.steps
    assert step.safety_floor == :needs_confirmation
    assert step.confirmations_required

    write_workflow!(home, "upgrade_read_only", """
    id: upgrade_read_only
    version: 1
    steps:
      - id: answer
        kind: action
        action: direct_answer
        confirm: true
        params:
          text: "Needs explicit step confirmation."
    """)

    assert {:ok, pending} =
             Runner.run("start_plan_run", %{workflow_id: "upgrade_read_only"}, context)

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "eval approval"},
               context
             )

    objective_id = get_in(approved, [:output_data, :objective_id])
    assert get_in(approved, [:output_data, :run_status]) == :needs_confirmation
    assert is_binary(get_in(approved, [:output_data, :confirmation_id]))
    assert [%{status: "blocked", result_summary: summary}] = Objectives.list_steps(objective_id)
    assert summary =~ "Plan/Build step confirmation"
  end

  test "plan cancellation is cooperative and records a durable reason", %{context: context} do
    assert_eval!("plan-cancel-cooperative-001")

    assert {:ok, pending} =
             Runner.run("start_plan_run", %{workflow_id: "multi_step"}, context)

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "eval approval"},
               context
             )

    objective_id = get_in(approved, [:output_data, :objective_id])

    assert {:ok, cancelled} =
             Runner.run(
               "cancel_plan_run",
               %{objective_id: objective_id, reason: "eval cancel"},
               context
             )

    assert cancelled.status == :cancelled
    assert {:ok, objective} = Objectives.get_objective(objective_id)
    assert objective.status == "cancelled"
    refute Enum.any?(Objectives.list_steps(objective_id), &(&1.status == "proposed"))
    assert Enum.any?(Objectives.list_events(objective_id), &(&1.summary =~ "eval cancel"))
  end

  test "delegate-agent previews and dispatch stay inside registered boundaries", %{
    context: context,
    home: home
  } do
    assert_eval!("subagent-delegation-permission-boundary-001")
    assert_eval!("delegate-agent-authority-boundary-001")

    server = :"v044_plan_build_eval_stub_#{System.unique_integer([:positive])}"
    start_supervised!({StubAgent, name: server})
    assert {:ok, _entry} = AgentRegistry.register("plan-build-stub", server, StubAgent, %{})

    copy_fixture!("with_delegate_agent", home)
    assert {:ok, expanded} = Workflows.preview("with_delegate_agent", %{}, context)

    assert [%{kind: :delegate_agent} = step] = expanded.preview.steps
    assert step.subagent_target == "plan-build-stub"
    assert step.permission == :objective_write

    assert {:ok, denied} =
             Runner.run(
               "delegate_agent",
               %{
                 user_id: "local",
                 objective_id: "obj_1",
                 step_id: "step_1",
                 delegate_agent_id: "plan-build-stub",
                 command: "not_allowed",
                 params: %{}
               },
               context
             )

    assert denied.status == :error
    assert denied.error == :invalid_delegate_command
  end

  defp assert_eval!(id), do: EvalInventory.row!(id)

  defp copy_fixture!(id, home) do
    File.cp!(
      Path.expand("../fixtures/v0.44/workflows/#{id}.yaml", __DIR__),
      Path.join([home, "workflows", "#{id}.yaml"])
    )
  end

  defp write_workflow!(home, id, content) do
    File.write!(Path.join([home, "workflows", "#{id}.yaml"]), content)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
