defmodule AllbertAssist.Actions.Coding.Bash do
  @moduledoc """
  Run a policy-bounded Pi-mode bash command inside the coding cwd jail.
  """

  use AllbertAssist.Action,
    permission: :coding_shell_execute,
    exposure: :internal,
    execution_mode: :coding_shell_execute,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "bash",
    description: "Run a cwd-jailed Level 1 local command for Pi-mode coding.",
    category: "coding",
    tags: ["coding", "bash", "shell", "confirmation_required"],
    schema: [
      action: [type: :string, required: false],
      mode: [type: {:or, [:string, :atom]}, required: false],
      executable: [type: :string, required: false],
      args: [type: {:list, :string}, required: false],
      command: [type: :string, required: false],
      cwd: [type: :string, required: false],
      timeout_ms: [type: :integer, required: false],
      max_output_bytes: [type: :integer, required: false],
      env: [type: :map, required: false],
      source_text: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Outbound.Gate
  alias AllbertAssist.Coding.BashSpec
  alias AllbertAssist.Coding.SessionGuard
  alias AllbertAssist.Execution.LocalRunner
  alias AllbertAssist.Maps
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate

  @output_preview_bytes 4_000

  @impl true
  def run(params, context) when is_map(params) do
    with {:ok, context} <- SessionGuard.ensure_active(context) do
      permission_decision =
        PermissionGate.authorize(:coding_shell_execute, action_context(params, context))

      if permission_decision.decision == :denied do
        blocked_response(permission_decision)
      else
        prepare_and_gate(params, context)
      end
    else
      {:error, reason, context} ->
        denied_response(
          %{reason: reason},
          SessionGuard.denied_decision(:coding_shell_execute, context, reason)
        )
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:coding_shell_execute, context)
    denied_response(%{reason: :invalid_params}, permission_decision)
  end

  defp prepare_and_gate(params, context) do
    with {:ok, prepared} <- BashSpec.normalize(params, context) do
      spec = %{
        action_name: "bash",
        permission: :coding_shell_execute,
        execution_mode: :coding_shell_execute,
        summary: prepared.summary,
        resume_params: prepared.resume_params
      }

      context = action_context(params, context)

      spec
      |> Gate.run(context, fn -> run_command(prepared, context) end)
      |> enrich_response(prepared)
    else
      {:error, error} ->
        permission_decision =
          PermissionGate.authorize(:coding_shell_execute, action_context(params, context))

        denied_response(error, permission_decision)
    end
  end

  defp run_command(prepared, context) do
    with {:ok, result} <- LocalRunner.run(prepared.command_spec, execution_opts(context)) do
      {:ok, result_summary(result, prepared)}
    end
  end

  defp execution_opts(%{objective_id: id}) when is_binary(id), do: [execution_id: id]
  defp execution_opts(_context), do: []

  defp enrich_response({:ok, response}, prepared) do
    status = normalized_status(response)
    payload = payload_for(status, response, prepared.summary)

    {:ok,
     response
     |> Map.put(:status, status)
     |> Map.update(:actions, [], fn actions ->
       Enum.map(actions, &Map.put(&1, :status, status))
     end)
     |> Map.put(:model_payload, payload)
     |> Map.put(:surface_payload, payload)
     |> Map.put(:output_data, output_data(response, prepared.summary))}
  end

  defp normalized_status(response) do
    response
    |> Map.get(:receipt, %{})
    |> Map.get(:status, Map.get(response, :status, :completed))
  end

  defp payload_for(:completed, response, _summary) do
    receipt = Map.get(response, :receipt, %{})

    [
      "bash completed: exit_status=",
      receipt |> Map.get(:exit_status) |> inspect(),
      " output_bytes=",
      receipt |> Map.get(:output_bytes, 0) |> to_string(),
      " truncated=",
      receipt |> Map.get(:truncated?, false) |> to_string(),
      "\n\n",
      Map.get(receipt, :stdout_preview, "")
    ]
    |> IO.iodata_to_binary()
  end

  defp payload_for(:timed_out, response, _summary) do
    receipt = Map.get(response, :receipt, %{})
    "bash timed out after #{get_in(receipt, [:command, :timeout_ms]) || "unknown"}ms"
  end

  defp payload_for(:needs_confirmation, response, summary) do
    [
      Map.get(response, :message, "bash needs confirmation"),
      "\nmode=",
      summary |> Map.get(:mode, :argv) |> to_string(),
      " executable=",
      summary |> Map.get(:executable) |> inspect(),
      " cwd=",
      summary |> Map.get(:cwd) |> inspect()
    ]
    |> IO.iodata_to_binary()
  end

  defp payload_for(_status, response, _summary), do: Map.get(response, :message, "")

  defp result_summary(result, prepared) do
    %{
      status: result.status,
      exit_status: result.exit_status,
      timed_out?: result.timed_out?,
      truncated?: result.truncated?,
      stdout_preview: preview(result.stdout),
      stderr_preview: preview(result.stderr),
      stderr_merged?: result.stderr_merged?,
      output_bytes: result.output_bytes,
      diagnostics: Redactor.redact(result.diagnostics),
      command: prepared.summary,
      mode: prepared.mode
    }
  end

  defp output_data(response, summary) do
    response
    |> Map.get(:receipt, %{command: summary})
    |> Map.take([
      :status,
      :exit_status,
      :timed_out?,
      :truncated?,
      :stdout_preview,
      :stderr_preview,
      :stderr_merged?,
      :output_bytes,
      :diagnostics,
      :command,
      :mode
    ])
  end

  defp preview(output) when is_binary(output) do
    output = Redactor.redact(output)

    if byte_size(output) > @output_preview_bytes do
      binary_part(output, 0, @output_preview_bytes) <> "\n[output preview truncated]"
    else
      output
    end
  end

  defp blocked_response(permission_decision) do
    {:ok,
     %{
       message:
         "Coding bash did not run: permission gate returned #{permission_decision.decision}.",
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [
         %{
           name: "bash",
           status: PermissionGate.response_status(permission_decision),
           permission: :coding_shell_execute,
           permission_decision: permission_decision,
           execution: :not_started
         }
       ]
     }}
  end

  defp denied_response(error, permission_decision) do
    reason = Map.get(error, :reason, error)

    {:ok,
     %{
       message: "Coding bash was denied: #{inspect(reason)}.",
       status: :denied,
       error: reason,
       command: Map.get(error, :command),
       permission_decision: permission_decision,
       actions: [
         %{
           name: "bash",
           status: :denied,
           permission: :coding_shell_execute,
           permission_decision: permission_decision,
           execution: :not_started,
           command: Map.get(error, :command),
           denial_reason: reason
         }
       ]
     }}
  end

  defp action_context(params, context) do
    Map.merge(context, %{
      request: normalized_request(context),
      resource: %{
        kind: :local_process,
        access: :execute,
        path: field(params, :cwd) || ".",
        command: command_summary(params)
      }
    })
  end

  defp command_summary(params) do
    %{
      executable: field(params, :executable),
      args: Redactor.redact(field(params, :args) || []),
      raw_shell?: is_binary(field(params, :command)) and field(params, :executable) in [nil, ""]
    }
  end

  defp normalized_request(context) do
    context
    |> Map.get(:request, %{})
    |> request_map()
    |> Map.put(:channel, channel_name(context))
  end

  defp request_map(request) when is_map(request), do: request
  defp request_map(_request), do: %{}

  defp channel_name(%{channel: %{name: name}}), do: name
  defp channel_name(%{"channel" => %{"name" => name}}), do: name
  defp channel_name(%{channel: channel}), do: channel
  defp channel_name(%{"channel" => channel}), do: channel
  defp channel_name(_context), do: :unknown

  defp field(map, key), do: Maps.field(map, key)
end
