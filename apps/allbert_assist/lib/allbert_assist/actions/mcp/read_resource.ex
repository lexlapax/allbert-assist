defmodule AllbertAssist.Actions.Mcp.ReadResource do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :mcp_resource_read,
    exposure: :internal,
    execution_mode: :mcp_resource_read,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "mcp_read_resource",
    description: "Read an MCP resource through Resource Access grants.",
    category: "mcp",
    tags: ["mcp", "resources", "resource_access", "internal"],
    schema: [
      server_id: [type: :string, required: true],
      uri: [type: :string, required: true],
      resource_uri: [type: :string, required: false],
      downstream_consumer: [type: :string, required: false],
      remember_scope: [type: :string, required: false],
      scope_kind: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Maps
  alias AllbertAssist.Mcp.Client
  alias AllbertAssist.Mcp.ServerConfig
  alias AllbertAssist.Resources.GrantHandoff
  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope
  alias AllbertAssist.Runtime.Audit
  alias AllbertAssist.Security.PermissionGate

  @permission :mcp_resource_read

  @impl true
  def run(params, context) when is_map(params) do
    server_id = field(params, :server_id)
    uri = field(params, :uri)
    permission_decision = PermissionGate.authorize(@permission, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, config} <- ServerConfig.resolve(server_id),
         {:ok, ref} <- resource_ref(config, uri, params) do
      cond do
        GrantHandoff.target_resumed?(context) ->
          execute(config, uri, ref, permission_decision, context)

        grant_context = grant_execution_context(ref, context) ->
          execute(config, uri, ref, permission_decision, grant_context)

        true ->
          create_confirmation(config, uri, params, ref, context, permission_decision)
      end
    else
      false -> {:ok, denied(server_id, uri, permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(server_id, uri, permission_decision, reason)}
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)
    {:ok, denied(nil, nil, permission_decision, :invalid_params)}
  end

  defp execute(config, uri, ref, permission_decision, context) do
    confirmation_id = get_in(context, [:confirmation, :id])

    case Client.read_resource(config, uri, context) do
      {:ok, result} ->
        summary = read_summary(result, ref)

        _audit =
          Audit.append(
            :mcp,
            :succeeded,
            config,
            permission_decision,
            Map.merge(
              %{
                action: "mcp_read_resource",
                status: :completed,
                confirmation_id: confirmation_id,
                resource_uri: ref.resource_uri,
                content_count: summary.content_count
              },
              audit_grant_attrs(context)
            )
          )

        {:ok,
         %{
           message: "MCP resource read completed for #{config.server_id}.",
           status: :completed,
           permission_decision: permission_decision,
           server_id: config.server_id,
           resource: summary,
           actions: [
             action(:completed, permission_decision, %{
               server_id: config.server_id,
               resource_uri: ref.resource_uri,
               content_count: summary.content_count,
               confirmation_id: confirmation_id
             })
             |> Map.put(:target_resumed?, GrantHandoff.target_resumed?(context))
             |> Map.merge(GrantHandoff.action_metadata(context))
           ]
         }}

      {:error, reason} ->
        _audit =
          Audit.append(:mcp, :failed, config, permission_decision, %{
            action: "mcp_read_resource",
            status: :failed,
            resource_uri: ref.resource_uri
          })

        {:ok, denied(config.server_id, uri, permission_decision, reason)}
    end
  end

  defp create_confirmation(config, uri, params, ref, context, permission_decision) do
    summary = read_request_summary(config, uri, ref)

    attrs = %{
      origin: Origin.from_context(context, "mcp_read_resource"),
      target_action: %{name: "mcp_read_resource", module: inspect(__MODULE__)},
      target_permission: @permission,
      target_execution_mode: :mcp_resource_read,
      security_decision: permission_decision,
      source_signal_id: source_signal_id(context),
      source_trace_id: source_trace_id(context),
      runner_metadata: runner_metadata(context),
      params_summary: summary,
      resume_params_ref: resume_params(config, uri, params, ref)
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        _audit =
          Audit.append(:mcp, :requested, config, permission_decision, %{
            action: "mcp_read_resource",
            status: :needs_confirmation,
            confirmation_id: confirmation_id(confirmation),
            resource_uri: ref.resource_uri
          })

        {:ok,
         %{
           message: "MCP resource read for #{config.server_id} needs Resource Access approval.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           server_id: config.server_id,
           resource: summary,
           confirmation: confirmation,
           confirmation_id: confirmation_id(confirmation),
           actions: [
             action(:needs_confirmation, permission_decision, %{
               server_id: config.server_id,
               resource_uri: ref.resource_uri,
               confirmation_id: confirmation_id(confirmation)
             })
             |> Map.put(:confirmation_metadata, confirmation_metadata(confirmation))
           ]
         }}

      {:error, reason} ->
        {:ok, denied(config.server_id, uri, permission_decision, reason)}
    end
  end

  defp denied(server_id, uri, permission_decision, reason) do
    %{
      message: "MCP resource read failed for #{server_id || "unknown"}: #{inspect(reason)}.",
      status: denied_status(permission_decision),
      error: reason,
      permission_decision: permission_decision,
      server_id: server_id,
      resource: %{server_id: server_id, uri: uri},
      actions: [
        action(:denied, permission_decision, %{server_id: server_id, uri: uri, error: reason})
      ]
    }
  end

  defp resource_ref(%ServerConfig{server_id: server_id}, uri, params)
       when is_binary(server_id) and is_binary(uri) do
    with {:ok, resource_uri} <- canonical_resource_uri(server_id, uri, params),
         {:ok, derived} <- ResourceURI.derived_fields(resource_uri) do
      Ref.new(%{
        resource_uri: resource_uri,
        origin_kind: :mcp_resource,
        canonical_id: resource_uri,
        operation_class: :mcp_resource_read,
        access_mode: :read,
        scope: scope(params, server_id),
        downstream_consumer: downstream_consumer(params),
        display_uri: uri,
        metadata: %{
          server_id: server_id,
          server_resource_uri: derived.server_resource_uri
        }
      })
    end
  end

  defp resource_ref(_config, _uri, _params), do: {:error, :invalid_mcp_resource}

  defp canonical_resource_uri(server_id, uri, params) do
    case field(params, :resource_uri) do
      value when is_binary(value) and value != "" -> ResourceURI.normalize(value)
      _other -> ResourceURI.mcp(server_id, uri)
    end
  end

  defp scope(params, server_id) do
    case field(params, :scope_kind) do
      _other ->
        Scope.mcp_server(server_id)
    end
  end

  defp grant_execution_context(ref, context) do
    case GrantHandoff.find_applicable([Ref.to_map(ref)], @permission, context) do
      {:ok, grants} -> GrantHandoff.put_applied(context, grants)
      _other -> nil
    end
  end

  defp read_request_summary(config, uri, ref) do
    %{
      server_id: config.server_id,
      uri: uri,
      resource_uri: ref.resource_uri,
      resource_refs: [Ref.to_map(ref)]
    }
  end

  defp read_summary(result, ref) do
    contents = Map.get(result, :contents, [])

    %{
      resource_uri: ref.resource_uri,
      content_count: length(contents),
      contents: Enum.map(contents, &content_summary/1)
    }
  end

  defp content_summary(content) when is_map(content) do
    %{
      "uri" => Map.get(content, "uri"),
      "mimeType" => Map.get(content, "mimeType"),
      "type" => Map.get(content, "type"),
      "text_preview" => preview(Map.get(content, "text")),
      "blob_bytes" => blob_bytes(Map.get(content, "blob"))
    }
    |> drop_nil_values()
  end

  defp content_summary(_content), do: %{}

  defp resume_params(config, uri, params, ref) do
    %{
      server_id: config.server_id,
      uri: uri,
      resource_uri: ref.resource_uri,
      downstream_consumer: downstream_consumer(params),
      scope_kind: field(params, :scope_kind)
    }
    |> drop_nil_values()
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "mcp_read_resource",
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      execution: :mcp_resource_read,
      mcp_metadata: metadata
    }
  end

  defp audit_grant_attrs(context) do
    case grant_ids(context) do
      [] -> %{}
      grant_ids -> %{grant_ids: grant_ids}
    end
  end

  defp grant_ids(context) do
    context
    |> GrantHandoff.action_metadata()
    |> get_in([:resource_grants, :grant_ids])
    |> List.wrap()
  end

  defp preview(text) when is_binary(text) do
    text
    |> String.slice(0, 240)
    |> then(fn preview ->
      if byte_size(text) > byte_size(preview), do: preview <> "...", else: preview
    end)
  end

  defp preview(_text), do: nil

  defp blob_bytes(blob) when is_binary(blob), do: byte_size(blob)
  defp blob_bytes(_blob), do: nil

  defp downstream_consumer(params),
    do: field(params, :downstream_consumer) || "mcp_resource_reader"

  defp denied_status(%{decision: :denied}), do: :denied
  defp denied_status(_permission_decision), do: :error

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

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
end
