defmodule AllbertAssist.Actions.Skills.RunSkillScript do
  @moduledoc """
  v0.09 skill script execution boundary.

  M3 resolves trusted skill script requests into durable confirmations and
  resumes approved requests through the same resource-gated spec. M4 adds the
  bounded process runner behind this action name.
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
      confirmation: [type: :map, required: false],
      confirmation_id: [type: :string, required: false],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
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

    cond do
      permission_decision.decision == :denied ->
        denied_response(spec, permission_decision, :permission_denied)

      approval_resume?(context) ->
        resume_approved_spec(spec, permission_decision, context)

      true ->
        create_confirmation(spec, params, context, permission_decision)
    end
  end

  defp denied_spec_response(spec, context) do
    permission_decision =
      PermissionGate.authorize(:skill_script_execute, script_context(spec, context))

    denied_response(spec, permission_decision, spec.denial_reason)
  end

  defp denied_response(spec, permission_decision, reason) do
    result = no_run_result(spec, reason)

    {:ok,
     %{
       message: "Skill script execution was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       script: SkillScriptSpec.summary(spec),
       result: result,
       actions: [
         %{
           name: "run_skill_script",
           status: :denied,
           permission: :skill_script_execute,
           permission_decision: permission_decision,
           execution: :not_started,
           script: SkillScriptSpec.summary(spec),
           result: result,
           denial_reason: reason
         }
       ]
     }}
  end

  defp create_confirmation(spec, params, context, permission_decision) do
    attrs = %{
      origin: origin(context),
      target_action: %{name: "run_skill_script", module: inspect(__MODULE__)},
      target_permission: :skill_script_execute,
      target_execution_mode: :skill_script_process,
      selected_skill: selected_skill(spec),
      capability_contract: spec.capability_contract,
      security_decision: permission_decision,
      source_signal_id: source_signal_id(context),
      source_trace_id: source_trace_id(context),
      runner_metadata: runner_metadata(context),
      params_summary: SkillScriptSpec.summary(spec),
      resume_params_ref: resume_params(spec, params)
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message: confirmation_message(spec, permission_decision, confirmation),
           status: :needs_confirmation,
           permission_decision: permission_decision,
           script: SkillScriptSpec.summary(spec),
           confirmation: confirmation,
           confirmation_id: confirmation_id(confirmation),
           actions: [
             %{
               name: "run_skill_script",
               status: :needs_confirmation,
               permission: :skill_script_execute,
               permission_decision: permission_decision,
               execution: :pending_confirmation,
               script: SkillScriptSpec.summary(spec),
               confirmation_id: confirmation_id(confirmation),
               confirmation_metadata: confirmation_metadata(confirmation)
             }
           ]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "Could not create confirmation request for skill script.",
           status: :error,
           error: reason,
           permission_decision: permission_decision,
           script: SkillScriptSpec.summary(spec),
           actions: [
             %{
               name: "run_skill_script",
               status: :error,
               permission: :skill_script_execute,
               permission_decision: permission_decision,
               execution: :not_started,
               script: SkillScriptSpec.summary(spec),
               error: reason
             }
           ]
         }}
    end
  end

  defp resume_approved_spec(spec, permission_decision, context) do
    result = runner_pending_result(spec, context)

    {:ok,
     %{
       message:
         "Skill script approval resumed and passed policy/digest re-check. Runner execution lands in v0.09 M4; no script process started.",
       status: :ready_to_execute,
       permission_decision: permission_decision,
       script: SkillScriptSpec.summary(spec),
       result: result,
       actions: [
         %{
           name: "run_skill_script",
           status: :ready_to_execute,
           permission: :skill_script_execute,
           permission_decision: permission_decision,
           execution: :runner_pending_m4,
           target_resumed?: true,
           script: SkillScriptSpec.summary(spec),
           result: result
         }
       ]
     }}
  end

  defp confirmation_message(spec, permission_decision, confirmation) do
    summary = SkillScriptSpec.summary(spec)

    """
    Skill script is ready for operator approval.

    Skill: #{summary.skill_name}
    Script: #{summary.script_path}
    Digest: #{summary.script_sha256}
    Working directory: #{summary.resolved_cwd}
    Permission gate decision: #{permission_decision.decision} for skill_script_execute.
    Confirmation request: #{confirmation_id(confirmation)}.
    Nothing has executed yet.
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

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp selected_skill(spec) do
    %{
      name: spec.skill_name,
      source_scope: spec.skill_source_scope,
      trust_status: spec.skill_trust_status,
      enabled?: spec.skill_enabled?,
      capability_contract: spec.capability_contract
    }
  end

  defp resume_params(spec, params) do
    %{
      action: "run_skill_script",
      skill_name: spec.skill_name,
      script_path: spec.script_path,
      expected_sha256: spec.actual_sha256 || spec.expected_sha256,
      args: spec.args,
      cwd: operator_cwd(spec),
      run_id: spec.run_id,
      env: Map.get(params, :env) || Map.get(params, "env") || %{},
      env_summary: spec.env_summary,
      timeout_ms: spec.timeout_ms,
      max_output_bytes: spec.max_output_bytes,
      source_text: Map.get(params, :source_text) || Map.get(params, "source_text")
    }
  end

  defp operator_cwd(%{cwd_source: :operator, cwd: cwd}), do: cwd
  defp operator_cwd(_spec), do: nil

  defp runner_pending_result(spec, context) do
    %{
      status: :runner_pending,
      exit_status: nil,
      timed_out?: false,
      truncated?: false,
      output_bytes: 0,
      stdout_preview: "",
      stderr_preview: "",
      digest_recheck: :matched,
      runner_backend: :pending_m4,
      confirmation_id: get_in(context, [:confirmation, :id]),
      script: SkillScriptSpec.summary(spec)
    }
  end

  defp no_run_result(spec, reason) do
    %{
      status: no_run_status(reason),
      exit_status: nil,
      timed_out?: false,
      truncated?: false,
      output_bytes: 0,
      stdout_preview: "",
      stderr_preview: "",
      digest_recheck: digest_recheck(reason),
      runner_backend: :not_started,
      failure_reason: reason,
      script: SkillScriptSpec.summary(spec)
    }
  end

  defp no_run_status(:digest_mismatch), do: :digest_mismatch
  defp no_run_status(_reason), do: :denied

  defp digest_recheck(:digest_mismatch), do: :mismatch
  defp digest_recheck(_reason), do: :not_checked

  defp confirmation_id(%{"id" => id}), do: id
  defp confirmation_id(_confirmation), do: nil

  defp confirmation_metadata(nil), do: nil

  defp confirmation_metadata(confirmation) do
    %{
      id: Map.get(confirmation, "id"),
      status: Map.get(confirmation, "status"),
      origin: Map.get(confirmation, "origin"),
      expires_at: Map.get(confirmation, "expires_at"),
      audit_path: Map.get(confirmation, "audit_path")
    }
  end

  defp origin(context) do
    request = Map.get(context, :request, %{})

    %{
      actor: Map.get(request, :operator_id, Map.get(context, :actor, "local")),
      channel: Map.get(request, :channel, Map.get(context, :channel, :unknown)),
      surface: Map.get(context, :surface, "run_skill_script"),
      session_id: Map.get(request, :session_id, Map.get(context, :session_id)),
      response_target: Map.get(context, :response_target)
    }
  end

  defp source_signal_id(context) do
    Map.get(context, :runner_requested_signal_id) ||
      get_in(context, [:request, :input_signal_id])
  end

  defp source_trace_id(context) do
    Map.get(context, :trace_id) ||
      get_in(context, [:request, :trace_id])
  end

  defp runner_metadata(context) do
    %{
      requested_signal_id: Map.get(context, :runner_requested_signal_id),
      selected_skill: Map.get(context, :selected_skill),
      selected_action: Map.get(context, :selected_action),
      action_capability: Map.get(context, :action_capability)
    }
  end
end
