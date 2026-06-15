defmodule AllbertAssist.Actions.Channels.SignalDoctor do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :channel_diagnostic,
    skill_backed?: false,
    confirmation: :not_required,
    name: "signal_doctor",
    description: "Check the configured Signal signal-cli channel without exposing secrets.",
    category: "channels",
    tags: ["channels", "signal", "doctor", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Channels.Signal.Doctor
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, result} <- Doctor.diagnose() do
      {:ok, completed(result, permission_decision)}
    else
      false -> {:ok, denied(permission_decision)}
      {:error, reason} -> {:ok, failed(permission_decision, reason)}
    end
  end

  defp completed(result, permission_decision) do
    %{
      message: message(result),
      status: :completed,
      doctor: result,
      diagnostics: result.diagnostics,
      permission_decision: permission_decision,
      actions: [
        action(:completed, permission_decision, %{
          doctor_status: result.status,
          auth_ok: result.auth_ok,
          endpoint_ok: result.endpoint_ok,
          adapter_status: result.adapter_status,
          control_mode: result.control_mode,
          diagnostics: result.diagnostics
        })
      ]
    }
  end

  defp denied(permission_decision) do
    %{
      message: permission_decision.reason,
      status: PermissionGate.response_status(permission_decision),
      doctor: %{},
      diagnostics: [],
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{error: :permission_denied})]
    }
  end

  defp failed(permission_decision, reason) do
    %{
      message: "Signal doctor failed.",
      status: :error,
      doctor: %{},
      diagnostics: [reason],
      permission_decision: permission_decision,
      actions: [action(:error, permission_decision, %{error: inspect(reason)})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "signal_doctor",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      channel_metadata: metadata
    }
  end

  defp message(result) do
    [
      "Signal doctor: status=#{result.status}",
      "auth_ok=#{result.auth_ok}",
      "endpoint_ok=#{result.endpoint_ok}",
      "adapter=#{result.adapter_status}",
      "control=#{result.control_mode}",
      "local_only=#{result.control_local_only}",
      diagnostic_text(result.diagnostics)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp diagnostic_text([]), do: ""

  defp diagnostic_text(diagnostics),
    do: "diagnostics=" <> Enum.map_join(diagnostics, ",", &to_string/1)
end
