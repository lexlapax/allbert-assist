defmodule AllbertAssist.Actions.Packages.RunPackageInstall do
  @moduledoc """
  Confirmed package-install action boundary.

  v0.10 runs only the npm profile after Settings Central policy, Security
  Central, and durable confirmation. pip remains preview-only.
  """

  use Jido.Action,
    name: "run_package_install",
    description: "Run a confirmed package manager install through v0.10 policy.",
    category: "packages",
    tags: ["packages", "package_install", "execution"],
    schema: [
      manager: [type: :string, required: true, doc: "Package manager name, such as npm."],
      package: [type: :string, required: false, doc: "Package requested by the operator."],
      packages: [type: {:list, :string}, required: false, doc: "Package specs requested."],
      version: [type: :string, required: false, doc: "Optional package version."],
      project_root: [type: :string, required: false, doc: "Target project root."],
      cwd: [type: :string, required: false, doc: "Target project root alias."],
      save_mode: [type: :string, required: false, doc: "prod, dev, optional, peer, or no-save."],
      timeout_ms: [type: :integer, required: false, doc: "Requested timeout in milliseconds."],
      max_output_bytes: [type: :integer, required: false, doc: "Requested output cap."],
      source_text: [type: :string, required: false, doc: "The original user prompt."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Execution.CommandSpec
  alias AllbertAssist.Execution.LocalRunner
  alias AllbertAssist.Packages.Audit
  alias AllbertAssist.Packages.InstallSpec
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) when is_map(params) do
    case InstallSpec.normalize(params, context: context) do
      {:ok, spec} ->
        run_allowed_spec(spec, params, context)

      {:error, spec} ->
        permission_decision =
          PermissionGate.authorize(:package_install, package_context(spec, context))

        denied_response(spec, permission_decision, spec.denial_reason)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:package_install, context)
    spec = %InstallSpec{policy_decision: :denied, denial_reason: :invalid_params}
    denied_response(spec, permission_decision, :invalid_params)
  end

  defp run_allowed_spec(spec, params, context) do
    permission_decision =
      PermissionGate.authorize(:package_install, package_context(spec, context))

    cond do
      permission_decision.decision == :denied ->
        denied_response(spec, permission_decision, :permission_denied)

      not spec.execution_available? ->
        denied_response(spec, permission_decision, :preview_only)

      approval_resume?(context) ->
        execute_spec(spec, permission_decision, context)

      true ->
        create_confirmation(spec, params, context, permission_decision)
    end
  end

  defp denied_response(spec, permission_decision, :preview_only) do
    reason = "pip execution requires strict hash and binary policy; preview only in v0.10."
    _audit = Audit.append(:denied, spec, permission_decision, %{denial_reason: reason})

    {:ok,
     %{
       message: reason,
       status: :denied,
       permission_decision: permission_decision,
       package_install: InstallSpec.summary(spec),
       actions: [
         %{
           name: "run_package_install",
           status: :denied,
           permission: :package_install,
           permission_decision: permission_decision,
           execution: :not_started,
           package_install: InstallSpec.summary(spec),
           denial_reason: reason
         }
       ]
     }}
  end

  defp denied_response(spec, permission_decision, reason) do
    _audit = Audit.append(:denied, spec, permission_decision, %{denial_reason: reason})

    {:ok,
     %{
       message: "Package install was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       package_install: InstallSpec.summary(spec),
       actions: [
         %{
           name: "run_package_install",
           status: :denied,
           permission: :package_install,
           permission_decision: permission_decision,
           execution: :not_started,
           package_install: InstallSpec.summary(spec),
           denial_reason: reason
         }
       ]
     }}
  end

  defp create_confirmation(spec, params, context, permission_decision) do
    attrs = %{
      origin: origin(context),
      target_action: %{name: "run_package_install", module: inspect(__MODULE__)},
      target_permission: :package_install,
      target_execution_mode: :package_manager_process,
      selected_skill: selected_skill(context),
      capability_contract: capability_contract(context),
      security_decision: permission_decision,
      source_signal_id: source_signal_id(context),
      source_trace_id: source_trace_id(context),
      runner_metadata: runner_metadata(context),
      params_summary: InstallSpec.summary(spec),
      resume_params_ref: InstallSpec.resume_params(spec, params)
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        _audit =
          Audit.append(:requested, spec, permission_decision, %{
            confirmation_id: confirmation_id(confirmation)
          })

        {:ok,
         %{
           message: confirmation_message(spec, permission_decision, confirmation),
           status: :needs_confirmation,
           permission_decision: permission_decision,
           package_install: InstallSpec.summary(spec),
           confirmation: confirmation,
           confirmation_id: confirmation_id(confirmation),
           actions: [
             %{
               name: "run_package_install",
               status: :needs_confirmation,
               permission: :package_install,
               permission_decision: permission_decision,
               execution: :pending_confirmation,
               package_install: InstallSpec.summary(spec),
               confirmation_id: confirmation_id(confirmation),
               confirmation_metadata: confirmation_metadata(confirmation)
             }
           ]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "Could not create confirmation request for package install.",
           status: :error,
           error: reason,
           permission_decision: permission_decision,
           package_install: InstallSpec.summary(spec),
           actions: [
             %{
               name: "run_package_install",
               status: :error,
               permission: :package_install,
               permission_decision: permission_decision,
               execution: :not_started,
               package_install: InstallSpec.summary(spec),
               error: reason
             }
           ]
         }}
    end
  end

  defp execute_spec(spec, permission_decision, context) do
    confirmation_id = get_in(context, [:confirmation, :id])
    command_spec = command_spec(spec)

    with {:ok, result} <- LocalRunner.run(command_spec) do
      _approved_audit =
        Audit.append(:approved, spec, permission_decision, %{confirmation_id: confirmation_id})

      _result_audit =
        Audit.append(result_event(result), spec, permission_decision, %{
          confirmation_id: confirmation_id,
          result: result_summary(result)
        })

      {:ok,
       %{
         message: execution_message(result),
         status: result_status(result),
         permission_decision: permission_decision,
         package_install: InstallSpec.summary(spec),
         result: result_summary(result),
         actions: [
           %{
             name: "run_package_install",
             status: result_status(result),
             permission: :package_install,
             permission_decision: permission_decision,
             execution: :package_manager_process,
             target_resumed?: true,
             package_install: InstallSpec.summary(spec),
             result: result_summary(result)
           }
         ]
       }}
    end
  end

  defp command_spec(spec) do
    %CommandSpec{
      executable: spec.profile.executable,
      args: spec.install_args,
      cwd: spec.target_root,
      resolved_cwd: spec.resolved_target_root,
      timeout_ms: spec.timeout_ms,
      max_output_bytes: spec.max_output_bytes,
      env: %{},
      requested_env_keys: [],
      env_summary: [],
      command_class: :mutating,
      command_profile: spec.profile.name,
      sandbox_level: 1,
      policy_decision: :allowed
    }
  end

  defp package_context(spec, context) do
    Map.merge(context, %{
      resource: %{
        kind: :package_manager_process,
        path: spec.resolved_target_root,
        package_install: InstallSpec.summary(spec)
      }
    })
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp confirmation_message(spec, permission_decision, confirmation) do
    summary = InstallSpec.summary(spec)

    """
    Package install is ready for operator approval.

    Manager: #{summary.manager}
    Packages: #{Enum.join(summary.packages, ", ")}
    Project root: #{summary.resolved_target_root}
    Execution argv: #{Enum.join(summary.execution_argv_preview, " ")}
    Permission gate decision: #{permission_decision.decision} for package_install.
    Confirmation request: #{confirmation_id(confirmation)}.
    Nothing has executed yet.
    """
    |> String.trim()
  end

  defp execution_message(%{status: :completed, exit_status: 0}) do
    "Package install executed with exit status 0."
  end

  defp execution_message(%{status: :completed, exit_status: exit_status}) do
    "Package install ran and failed with exit status #{exit_status}."
  end

  defp execution_message(%{status: :timed_out}) do
    "Package install timed out."
  end

  defp execution_message(%{status: :denied}) do
    "Package install was denied before the package runner started."
  end

  defp result_status(%{status: :completed, exit_status: 0}), do: :completed
  defp result_status(%{status: :completed}), do: :failed
  defp result_status(%{status: :timed_out}), do: :timed_out
  defp result_status(%{status: :denied}), do: :denied

  defp result_event(%{status: :timed_out}), do: :timed_out
  defp result_event(%{status: :completed, exit_status: 0}), do: :succeeded
  defp result_event(%{status: :completed}), do: :failed
  defp result_event(%{status: :denied}), do: :denied

  defp result_summary(result) do
    %{
      status: result_status(result),
      exit_status: result.exit_status,
      timed_out?: result.timed_out?,
      truncated?: result.truncated?,
      stdout_preview: preview(result.stdout),
      stderr_preview: preview(result.stderr),
      stderr_merged?: result.stderr_merged?,
      output_bytes: result.output_bytes,
      diagnostics: result.diagnostics,
      command: result.command
    }
  end

  defp preview(output) when is_binary(output) do
    if byte_size(output) > 2000, do: binary_part(output, 0, 2000), else: output
  end

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
      surface: Map.get(context, :surface, "run_package_install"),
      session_id: Map.get(request, :session_id, Map.get(context, :session_id)),
      response_target: Map.get(context, :response_target)
    }
  end

  defp selected_skill(context) do
    metadata = Map.get(context, :skill_metadata, %{})

    %{
      name: Map.get(context, :selected_skill),
      source_scope: Map.get(metadata, :source_scope),
      trust_status: Map.get(metadata, :trust_status),
      capability_contract: Map.get(metadata, :capability_contract)
    }
  end

  defp capability_contract(context) do
    context
    |> Map.get(:skill_metadata, %{})
    |> Map.get(:capability_contract, %{})
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
