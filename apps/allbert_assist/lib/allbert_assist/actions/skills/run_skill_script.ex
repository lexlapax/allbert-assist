defmodule AllbertAssist.Actions.Skills.RunSkillScript do
  @moduledoc """
  v0.09 skill script execution boundary.

  M2 resolves trusted skill script requests into an inert resource-gated spec.
  Later milestones add durable confirmation and the bounded runner behind this
  same action name.
  """

  use Jido.Action,
    name: "run_skill_script",
    description: "Run a confirmed trusted Agent Skill script resource.",
    category: "skills",
    tags: ["skills", "scripts", "skill_script_execute", "confirmation_required"],
    schema: [
      skill_name: [type: :string, required: true, doc: "Trusted selected skill name."],
      script_path: [type: :string, required: true, doc: "Inventoried script resource path."],
      args: [type: {:list, :string}, required: false, doc: "Explicit script argv list."],
      cwd: [type: :string, required: false, doc: "Working directory inside an allowed root."],
      env: [type: :map, required: false, doc: "Requested environment values filtered by policy."],
      timeout_ms: [type: :integer, required: false, doc: "Requested timeout in milliseconds."],
      max_output_bytes: [type: :integer, required: false, doc: "Requested output cap."],
      expected_sha256: [
        type: :string,
        required: false,
        doc: "Expected script resource digest for approval re-checks."
      ],
      source_text: [type: :string, required: false, doc: "Original operator prompt."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      script: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Execution.SkillScriptSpec
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) when is_map(params) do
    case SkillScriptSpec.normalize(params, context: context) do
      {:ok, spec} ->
        spec_response(spec, params, context)

      {:error, spec} ->
        denied_spec_response(spec, context)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:skill_script_execute, context)

    {:ok,
     %{
       message: "Skill script execution was denied: invalid script parameters.",
       status: :denied,
       permission_decision: permission_decision,
       script: nil,
       actions: [
         %{
           name: "run_skill_script",
           status: :denied,
           permission: :skill_script_execute,
           permission_decision: permission_decision,
           execution: :not_started,
           denial_reason: :invalid_params
         }
       ]
     }}
  end

  defp spec_response(spec, params, context) do
    permission_decision =
      PermissionGate.authorize(:skill_script_execute, script_context(spec, context))

    if permission_decision.decision == :denied do
      denied_response(spec, permission_decision, :permission_denied)
    else
      {:ok,
       %{
         message: ready_message(spec, permission_decision),
         status: PermissionGate.response_status(permission_decision),
         permission_decision: permission_decision,
         script: SkillScriptSpec.summary(spec),
         actions: [
           %{
             name: "run_skill_script",
             status: :spec_resolved,
             permission: :skill_script_execute,
             permission_decision: permission_decision,
             execution: :pending_confirmation_not_created,
             script: SkillScriptSpec.summary(spec),
             input: safe_input(params),
             diagnostics: [:v0_09_confirmation_lands_in_m3, :v0_09_runner_lands_in_m4]
           }
         ]
       }}
    end
  end

  defp denied_spec_response(spec, context) do
    permission_decision =
      PermissionGate.authorize(:skill_script_execute, script_context(spec, context))

    denied_response(spec, permission_decision, spec.denial_reason)
  end

  defp denied_response(spec, permission_decision, reason) do
    {:ok,
     %{
       message: "Skill script execution was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       script: SkillScriptSpec.summary(spec),
       actions: [
         %{
           name: "run_skill_script",
           status: :denied,
           permission: :skill_script_execute,
           permission_decision: permission_decision,
           execution: :not_started,
           script: SkillScriptSpec.summary(spec),
           denial_reason: reason
         }
       ]
     }}
  end

  defp ready_message(spec, permission_decision) do
    summary = SkillScriptSpec.summary(spec)

    """
    Skill script spec is valid and ready for operator approval.

    Skill: #{summary.skill_name}
    Script: #{summary.script_path}
    Digest: #{summary.script_sha256}
    Working directory: #{summary.resolved_cwd}
    Permission gate decision: #{permission_decision.decision} for skill_script_execute.
    Nothing has executed yet. Durable confirmation creation lands in v0.09 M3.
    """
    |> String.trim()
  end

  defp script_context(spec, context) do
    Map.merge(context, %{
      resource: %{
        kind: :skill_script,
        skill_name: spec.skill_name,
        script_path: spec.script_path,
        sha256: spec.actual_sha256 || spec.expected_sha256,
        cwd: spec.resolved_cwd,
        summary: SkillScriptSpec.summary(spec)
      }
    })
  end

  defp safe_input(params) do
    %{
      skill_name: Map.get(params, :skill_name) || Map.get(params, "skill_name"),
      script_path: Map.get(params, :script_path) || Map.get(params, "script_path"),
      args: Map.get(params, :args) || Map.get(params, "args") || [],
      cwd: Map.get(params, :cwd) || Map.get(params, "cwd"),
      env_keys:
        params
        |> Map.get(:env, Map.get(params, "env", %{}))
        |> env_keys(),
      timeout_ms: Map.get(params, :timeout_ms) || Map.get(params, "timeout_ms"),
      max_output_bytes: Map.get(params, :max_output_bytes) || Map.get(params, "max_output_bytes"),
      expected_sha256: Map.get(params, :expected_sha256) || Map.get(params, "expected_sha256")
    }
  end

  defp env_keys(env) when is_map(env),
    do: env |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

  defp env_keys(_env), do: []
end
