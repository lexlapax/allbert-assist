defmodule AllbertAssist.Actions.Intent.RunShellCommand do
  @moduledoc """
  Confirmed Level 1 local shell command execution.

  The action does not accept shell strings. It normalizes an explicit
  executable plus argv list through the v0.08 local execution policy, creates a
  durable confirmation for allowed specs, and runs only when invoked from the
  approval resume path.
  """

  use AllbertAssist.Action,
    permission: :command_execute,
    exposure: :agent,
    execution_mode: :local_process,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    notes:
      "v0.08 Level 1 local process execution; creates a durable confirmation before running.",
    name: "run_shell_command",
    description: "Run a confirmed Level 1 local command spec through the local runner.",
    category: "intent",
    tags: ["intent", "shell", "command_execute", "confirmation_required"],
    schema: [
      action: [type: :string, required: false],
      executable: [type: :string, required: true, doc: "Executable name or path."],
      args: [type: {:list, :string}, required: false, doc: "Explicit argv list."],
      cwd: [type: :string, required: true, doc: "Working directory inside an allowed root."],
      timeout_ms: [type: :integer, required: false, doc: "Requested timeout in milliseconds."],
      max_output_bytes: [type: :integer, required: false, doc: "Requested output cap."],
      source_text: [type: :string, required: false, doc: "Original operator prompt."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Execution.CommandSpec
  alias AllbertAssist.Execution.LocalRunner
  alias AllbertAssist.Runtime.Audit
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) when is_map(params) do
    case CommandSpec.normalize(params, context: context) do
      {:ok, spec} ->
        run_allowed_spec(spec, params, context)

      {:error, spec} ->
        denied_spec_response(spec, context)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:command_execute, context)

    {:ok,
     %{
       message: "Shell command execution was denied: invalid command parameters.",
       status: :denied,
       permission_decision: permission_decision,
       command: nil,
       actions: [
         %{
           name: "run_shell_command",
           status: :denied,
           permission: :command_execute,
           permission_decision: permission_decision,
           execution: :not_started,
           denial_reason: :invalid_params
         }
       ]
     }}
  end

  defp run_allowed_spec(spec, params, context) do
    permission_decision =
      PermissionGate.authorize(:command_execute, command_context(spec, context))

    cond do
      permission_decision.decision == :denied ->
        denied_response(spec, permission_decision, :permission_denied)

      approval_resume?(context) ->
        execute_spec(spec, permission_decision, context)

      true ->
        create_confirmation(spec, params, context, permission_decision)
    end
  end

  defp denied_spec_response(spec, context) do
    permission_decision =
      PermissionGate.authorize(:command_execute, command_context(spec, context))

    denied_response(spec, permission_decision, spec.denial_reason)
  end

  defp denied_response(spec, permission_decision, reason) do
    _audit =
      Audit.append(:shell_command, :denied, spec, permission_decision, %{denial_reason: reason})

    {:ok,
     %{
       message: "Shell command execution was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       command: CommandSpec.summary(spec),
       actions: [
         %{
           name: "run_shell_command",
           status: :denied,
           permission: :command_execute,
           permission_decision: permission_decision,
           execution: :not_started,
           command: CommandSpec.summary(spec),
           denial_reason: reason
         }
       ]
     }}
  end

  defp create_confirmation(spec, params, context, permission_decision) do
    attrs = %{
      origin: origin(context),
      target_action: %{name: "run_shell_command", module: inspect(__MODULE__)},
      target_permission: :command_execute,
      target_execution_mode: :local_process,
      selected_skill: selected_skill(context),
      capability_contract: capability_contract(context),
      security_decision: permission_decision,
      source_signal_id: source_signal_id(context),
      source_trace_id: source_trace_id(context),
      runner_metadata: runner_metadata(context),
      params_summary: CommandSpec.summary(spec),
      resume_params_ref: resume_params(spec, params)
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        _audit =
          Audit.append(:shell_command, :requested, spec, permission_decision, %{
            confirmation_id: confirmation_id(confirmation)
          })

        {:ok,
         %{
           message: confirmation_message(spec, permission_decision, confirmation),
           status: :needs_confirmation,
           permission_decision: permission_decision,
           command: CommandSpec.summary(spec),
           confirmation: confirmation,
           confirmation_id: confirmation_id(confirmation),
           actions: [
             %{
               name: "run_shell_command",
               status: :needs_confirmation,
               permission: :command_execute,
               permission_decision: permission_decision,
               execution: :pending_confirmation,
               command: CommandSpec.summary(spec),
               confirmation_id: confirmation_id(confirmation),
               confirmation_metadata: confirmation_metadata(confirmation)
             }
           ]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "Could not create confirmation request for shell command.",
           status: :error,
           error: reason,
           permission_decision: permission_decision,
           command: CommandSpec.summary(spec),
           actions: [
             %{
               name: "run_shell_command",
               status: :error,
               permission: :command_execute,
               permission_decision: permission_decision,
               execution: :not_started,
               command: CommandSpec.summary(spec),
               error: reason
             }
           ]
         }}
    end
  end

  defp execute_spec(spec, permission_decision, context) do
    confirmation_id = get_in(context, [:confirmation, :id])

    with {:ok, result} <- LocalRunner.run(spec) do
      _approved_audit =
        Audit.append(:shell_command, :approved, spec, permission_decision, %{
          confirmation_id: confirmation_id
        })

      _result_audit =
        Audit.append(:shell_command, result_event(result), spec, permission_decision, %{
          confirmation_id: confirmation_id,
          result: result_summary(result)
        })

      {:ok,
       %{
         message: execution_message(result),
         status: result_status(result),
         permission_decision: permission_decision,
         command: CommandSpec.summary(spec),
         result: result_summary(result),
         actions: [
           %{
             name: "run_shell_command",
             status: result_status(result),
             permission: :command_execute,
             permission_decision: permission_decision,
             execution: :local_process,
             target_resumed?: true,
             command: CommandSpec.summary(spec),
             result: result_summary(result)
           }
         ]
       }}
    end
  end

  defp command_context(spec, context) do
    Map.merge(context, %{
      resource: %{
        kind: :local_process,
        path: spec.resolved_cwd,
        command: CommandSpec.summary(spec)
      }
    })
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp confirmation_message(spec, permission_decision, confirmation) do
    """
    Shell command is ready for operator approval.

    Command: #{render_command(spec)}
    Working directory: #{spec.resolved_cwd}
    Permission gate decision: #{permission_decision.decision} for command_execute.
    Confirmation request: #{confirmation_id(confirmation)}.
    Nothing has executed yet.
    """
    |> String.trim()
  end

  defp execution_message(result) do
    case result.status do
      :completed ->
        "Shell command executed with exit status #{result.exit_status}."

      :timed_out ->
        "Shell command timed out after #{get_in(result, [:command, :timeout_ms])}ms."

      :denied ->
        "Shell command execution was denied before the local runner started."
    end
  end

  defp result_status(%{status: :completed}), do: :completed
  defp result_status(%{status: :timed_out}), do: :timed_out
  defp result_status(%{status: :denied}), do: :denied

  defp result_event(%{status: :timed_out}), do: :timed_out
  defp result_event(%{status: :completed, exit_status: 0}), do: :succeeded
  defp result_event(%{status: :completed}), do: :failed
  defp result_event(%{status: :denied}), do: :denied

  defp result_summary(result) do
    %{
      status: result.status,
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

  defp resume_params(spec, params) do
    %{
      action: "run_shell_command",
      executable: spec.executable,
      args: spec.args,
      cwd: spec.cwd,
      timeout_ms: spec.timeout_ms,
      max_output_bytes: spec.max_output_bytes,
      source_text: Map.get(params, :source_text) || Map.get(params, "source_text")
    }
  end

  defp render_command(spec) do
    ([spec.executable] ++ spec.args)
    |> Enum.map(&inspect/1)
    |> Enum.join(" ")
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
    Origin.from_context(context, "run_shell_command")
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
