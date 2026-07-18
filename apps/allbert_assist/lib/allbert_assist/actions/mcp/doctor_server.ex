defmodule AllbertAssist.Actions.Mcp.DoctorServer do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :mcp_doctor,
    skill_backed?: false,
    confirmation: :not_required,
    name: "mcp_doctor_server",
    description: "Check a configured MCP server without exposing secrets.",
    category: "mcp",
    tags: ["mcp", "doctor", "read_only", "internal"],
    schema: [
      server_id: [type: :string, required: true],
      include_discovery: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Maps
  alias AllbertAssist.Mcp.Doctor
  alias AllbertAssist.Mcp.ServerConfig
  alias AllbertAssist.Runtime.Audit
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    server_id = field(params, :server_id)
    include_discovery? = field(params, :include_discovery)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, doctor} <-
           Doctor.diagnose(server_id, context, include_discovery: include_discovery? != false) do
      audit(server_id, permission_decision, doctor)
      {:ok, completed(server_id, permission_decision, doctor)}
    else
      false ->
        {:ok, denied(server_id, permission_decision, :permission_denied)}

      {:error, reason} ->
        {:ok, denied(server_id, permission_decision, reason)}
    end
  end

  defp completed(server_id, permission_decision, doctor) do
    %{
      message: message(server_id, doctor),
      status: if(doctor.endpoint_ok, do: :completed, else: :failed),
      permission_decision: permission_decision,
      server_id: server_id,
      doctor: doctor,
      diagnostics: doctor.diagnostics,
      actions: [
        action(if(doctor.endpoint_ok, do: :completed, else: :failed), permission_decision, %{
          server_id: server_id,
          transport_kind: doctor.transport_kind,
          endpoint_kind: doctor.endpoint_kind,
          endpoint_ok: doctor.endpoint_ok,
          redacted_host: doctor.redacted_host,
          tool_count: doctor.tool_count,
          resource_count: doctor.resource_count,
          diagnostics: doctor.diagnostics
        })
      ]
    }
  end

  defp denied(server_id, permission_decision, reason) do
    %{
      message: "MCP doctor failed for #{server_id || "unknown"}: #{inspect(reason)}.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      server_id: server_id,
      doctor: %{},
      diagnostics: [],
      actions: [action(:denied, permission_decision, %{server_id: server_id, error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "mcp_doctor_server",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      mcp_metadata: metadata
    }
  end

  defp audit(server_id, permission_decision, doctor) do
    with {:ok, config} <- ServerConfig.resolve(server_id) do
      Audit.append(
        :mcp,
        if(doctor.endpoint_ok, do: :succeeded, else: :failed),
        config,
        permission_decision,
        %{
          action: "mcp_doctor_server",
          status: if(doctor.endpoint_ok, do: :completed, else: :failed),
          tool_count: doctor.tool_count,
          resource_count: doctor.resource_count,
          diagnostics: doctor.diagnostics
        }
      )
    end
  end

  defp message(server_id, doctor) do
    [
      "MCP server #{server_id}: transport=#{doctor.transport_kind}, endpoint_kind=#{doctor.endpoint_kind}, endpoint_ok=#{doctor.endpoint_ok}, host=#{doctor.redacted_host}.",
      "Discovery: tools_listable=#{doctor.tools_listable}, resources_listable=#{doctor.resources_listable}, tool_count=#{doctor.tool_count}, resource_count=#{doctor.resource_count}.",
      diagnostic_text(doctor.diagnostics)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp diagnostic_text([]), do: ""

  defp diagnostic_text(diagnostics) do
    diagnostics
    |> Enum.map(& &1.message)
    |> Enum.join(" ")
  end

  defp field(map, key), do: Maps.field_truthy(map, key)
end
