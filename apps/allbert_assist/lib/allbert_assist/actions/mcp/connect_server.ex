defmodule AllbertAssist.Actions.Mcp.ConnectServer do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :mcp_server_connect,
    exposure: :internal,
    execution_mode: :mcp_server_connect,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "mcp_server_connect",
    description: "Configure a discovered MCP server after explicit operator consent.",
    category: "mcp",
    tags: ["mcp", "registry", "connect", "confirmation_required", "internal"],
    schema: [
      candidate_id: [type: :string, required: true],
      server_id: [type: :string, required: false],
      enable_on_connect: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Mcp.ConnectSpec
  alias AllbertAssist.Mcp.ServerTrust
  alias AllbertAssist.Repo
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Tools.Discovery
  alias AllbertAssist.Tools.Discovery.EvaluationReport

  @permission :mcp_server_connect

  @impl true
  def run(params, context) when is_map(params) do
    candidate_id = field(params, :candidate_id)
    permission_decision = PermissionGate.authorize(@permission, context)

    with candidate_id when is_binary(candidate_id) and candidate_id != "" <- candidate_id,
         false <- permission_decision.decision == :denied,
         {:ok, candidate} <- Discovery.get_candidate(candidate_id),
         manifest when is_map(manifest) and map_size(manifest) > 0 <- candidate.registry_record,
         {:ok, spec} <- ConnectSpec.build(candidate_map(candidate), manifest, params),
         {:ok, evaluation_report} <- evaluation_report(candidate, manifest, spec) do
      if approved_resume?(context) do
        connect(spec, candidate, evaluation_report, params, context, permission_decision)
      else
        create_confirmation(spec, evaluation_report, params, context, permission_decision)
      end
    else
      true -> {:ok, denied(candidate_id, nil, permission_decision, :permission_denied)}
      nil -> {:ok, denied(candidate_id, nil, permission_decision, :missing_candidate_id)}
      "" -> {:ok, denied(candidate_id, nil, permission_decision, :missing_candidate_id)}
      %{} -> {:ok, denied(candidate_id, nil, permission_decision, :missing_manifest)}
      {:error, reason} -> {:ok, denied(candidate_id, nil, permission_decision, reason)}
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)
    {:ok, denied(nil, nil, permission_decision, :invalid_params)}
  end

  defp connect(spec, candidate, evaluation_report, params, context, permission_decision) do
    enable_on_connect? = field(params, :enable_on_connect, false) == true

    with :ok <- write_settings(spec, enable_on_connect?),
         {:ok, trust_record} <- write_trust_record(spec, candidate, evaluation_report, context) do
      {:ok,
       %{
         message:
           "MCP server #{spec.server_id} configured from discovery candidate #{spec.candidate_id}.",
         status: :completed,
         permission_decision: permission_decision,
         server_id: spec.server_id,
         connection: %{
           server_id: spec.server_id,
           candidate_id: spec.candidate_id,
           enabled: enable_on_connect?,
           transport: spec.transport,
           endpoint_fingerprint: spec.endpoint_fingerprint,
           tool_definition_hash: spec.tool_definition_hash,
           trust_record: ServerTrust.to_map(trust_record)
         },
         actions: [
           action(:completed, permission_decision, %{
             server_id: spec.server_id,
             candidate_id: spec.candidate_id,
             enabled: enable_on_connect?,
             confirmation_id: get_in(context, [:confirmation, :id])
           })
         ]
       }}
    else
      {:error, reason} ->
        {:ok, denied(spec.candidate_id, spec.server_id, permission_decision, reason)}
    end
  end

  defp create_confirmation(spec, evaluation_report, params, context, permission_decision) do
    summary = ConnectSpec.consent_summary(spec, evaluation_report)

    attrs = %{
      origin: Origin.from_context(context, "mcp_server_connect"),
      target_action: %{name: "mcp_server_connect", module: inspect(__MODULE__)},
      target_permission: @permission,
      target_execution_mode: :mcp_server_connect,
      security_decision: permission_decision,
      source_signal_id: source_signal_id(context),
      source_trace_id: source_trace_id(context),
      runner_metadata: runner_metadata(context),
      params_summary: summary,
      resume_params_ref: resume_params(spec, params)
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message: "MCP server #{spec.server_id} needs connection confirmation.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           server_id: spec.server_id,
           connection: summary,
           confirmation: confirmation,
           confirmation_id: confirmation_id(confirmation),
           actions: [
             action(:needs_confirmation, permission_decision, %{
               server_id: spec.server_id,
               candidate_id: spec.candidate_id,
               confirmation_id: confirmation_id(confirmation)
             })
             |> Map.put(:confirmation_metadata, confirmation_metadata(confirmation))
           ]
         }}

      {:error, reason} ->
        {:ok, denied(spec.candidate_id, spec.server_id, permission_decision, reason)}
    end
  end

  defp write_settings(spec, enable_on_connect?) do
    spec
    |> ConnectSpec.settings_writes(enable_on_connect?)
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
      case Settings.put(key, value, %{audit?: false}) do
        {:ok, _setting} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:settings_write_failed, key, reason}}}
      end
    end)
  end

  defp write_trust_record(spec, candidate, evaluation_report, context) do
    ServerTrust.upsert(%{
      server_id: spec.server_id,
      candidate_id: candidate.id,
      tool_definition_hash: spec.tool_definition_hash,
      trust_status: "trusted",
      transport: Atom.to_string(spec.transport),
      endpoint_fingerprint: spec.endpoint_fingerprint,
      manifest: spec.manifest,
      evaluation_report: evaluation_report,
      connected_at: DateTime.utc_now(),
      connected_by: actor(context),
      metadata: %{
        required_secret_ref_count: length(spec.required_secret_refs),
        exact_command?: not is_nil(spec.exact_command),
        exact_url?: not is_nil(spec.exact_url)
      }
    })
  end

  defp evaluation_report(candidate, manifest, spec) do
    case Repo.get(EvaluationReport, "eval:#{candidate.id}") do
      %EvaluationReport{} = report ->
        {:ok,
         report
         |> Discovery.evaluation_to_map()
         |> Map.put(:tool_definition_hash, spec.tool_definition_hash)}

      nil ->
        with {:ok, report} <-
               Discovery.evaluate_server(manifest, %{
                 candidate_id: candidate.id,
                 provider: candidate.provider,
                 remote_server_id: candidate.remote_server_id,
                 probe?: false
               }),
             {:ok, report_record} <- Discovery.upsert_evaluation_report(candidate.id, report) do
          {:ok,
           report_record
           |> Discovery.evaluation_to_map()
           |> Map.put(:tool_definition_hash, spec.tool_definition_hash)}
        end
    end
  end

  defp denied(candidate_id, server_id, permission_decision, reason) do
    %{
      message: "MCP server connect failed for #{candidate_id || "unknown"}: #{inspect(reason)}.",
      status: denied_status(permission_decision),
      error: reason,
      permission_decision: permission_decision,
      server_id: server_id,
      connection: %{candidate_id: candidate_id, server_id: server_id},
      actions: [
        action(:denied, permission_decision, %{
          candidate_id: candidate_id,
          server_id: server_id,
          error: reason
        })
      ]
    }
  end

  defp denied_status(%{decision: :denied}), do: :denied
  defp denied_status(_decision), do: :failed

  defp action(status, permission_decision, metadata) do
    %{
      name: "mcp_server_connect",
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      execution: :mcp_server_connect,
      mcp_metadata: metadata
    }
  end

  defp candidate_map(candidate) do
    %{
      id: candidate.id,
      name: candidate.name,
      remote_server_id: candidate.remote_server_id
    }
  end

  defp resume_params(spec, params) do
    %{
      candidate_id: spec.candidate_id,
      server_id: spec.server_id,
      enable_on_connect: field(params, :enable_on_connect, false)
    }
  end

  defp approved_resume?(context), do: get_in(context, [:confirmation, :approved?]) == true

  defp confirmation_id(%{"id" => id}), do: id
  defp confirmation_id(_confirmation), do: nil

  defp confirmation_metadata(confirmation) do
    %{
      id: Map.get(confirmation, "id"),
      status: Map.get(confirmation, "status"),
      origin: Map.get(confirmation, "origin"),
      expires_at: Map.get(confirmation, "expires_at"),
      audit_path: Map.get(confirmation, "audit_path")
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
      selected_action: Map.get(context, :selected_action),
      action_capability: Map.get(context, :action_capability)
    }
    |> drop_nil_values()
  end

  defp actor(context), do: Map.get(context, :actor) || Map.get(context, "actor")

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
end
