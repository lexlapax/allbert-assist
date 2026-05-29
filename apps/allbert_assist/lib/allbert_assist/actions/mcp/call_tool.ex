defmodule AllbertAssist.Actions.Mcp.CallTool do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :mcp_tool_call,
    exposure: :internal,
    execution_mode: :mcp_tool_call,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "mcp_call_tool",
    description: "Call a configured MCP tool after durable operator confirmation.",
    category: "mcp",
    tags: ["mcp", "tools", "confirmation_required", "internal"],
    schema: [
      server_id: [type: :string, required: true],
      tool_name: [type: :string, required: true],
      arguments: [type: :map, required: true],
      downstream_consumer: [type: :string, required: false],
      idempotency_key: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Mcp.Client
  alias AllbertAssist.Mcp.ServerConfig
  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope
  alias AllbertAssist.Runtime.Audit
  alias AllbertAssist.Security.PermissionGate

  @permission :mcp_tool_call

  @impl true
  def run(%{arguments: arguments} = params, context) when is_map(arguments),
    do: run_tool(params, context)

  def run(%{"arguments" => arguments} = params, context) when is_map(arguments),
    do: run_tool(params, context)

  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(@permission, context)

    {:ok,
     denied(
       field(params, :server_id),
       field(params, :tool_name),
       permission_decision,
       :invalid_arguments
     )}
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)
    {:ok, denied(nil, nil, permission_decision, :invalid_params)}
  end

  defp run_tool(params, context) do
    server_id = field(params, :server_id)
    tool_name = field(params, :tool_name)
    arguments = field(params, :arguments, %{})
    permission_decision = PermissionGate.authorize(@permission, context)

    with false <- permission_decision.decision == :denied,
         {:ok, config} <- ServerConfig.resolve(server_id),
         :ok <- server_enabled(config),
         :ok <- tool_allowed(config, tool_name),
         :ok <- confirmation_allowed(config),
         {:ok, ref} <- tool_ref(config, tool_name, params) do
      if approved_resume?(context) do
        execute(config, tool_name, arguments, ref, permission_decision, context)
      else
        create_confirmation(
          config,
          tool_name,
          arguments,
          params,
          ref,
          context,
          permission_decision
        )
      end
    else
      true -> {:ok, denied(server_id, tool_name, permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(server_id, tool_name, permission_decision, reason)}
    end
  end

  defp execute(config, tool_name, arguments, ref, permission_decision, context) do
    confirmation_id = get_in(context, [:confirmation, :id])

    case Client.call_tool(config, tool_name, arguments, context) do
      {:ok, result} ->
        summary = result_summary(config, tool_name, arguments, result, ref)

        _audit =
          Audit.append(:mcp, :succeeded, config, permission_decision, %{
            action: "mcp_call_tool",
            status: :completed,
            confirmation_id: confirmation_id,
            resource_uri: ref.resource_uri,
            tool_name: tool_name,
            argument_keys: summary.argument_keys,
            result_keys: summary.result_keys
          })

        {:ok,
         %{
           message: "MCP tool #{tool_name} completed for #{config.server_id}.",
           status: :completed,
           permission_decision: permission_decision,
           server_id: config.server_id,
           tool_call: summary,
           actions: [
             action(:completed, permission_decision, %{
               server_id: config.server_id,
               tool_name: tool_name,
               resource_uri: ref.resource_uri,
               confirmation_id: confirmation_id,
               argument_keys: summary.argument_keys,
               result_keys: summary.result_keys
             })
           ]
         }}

      {:error, reason} ->
        _audit =
          Audit.append(:mcp, :failed, config, permission_decision, %{
            action: "mcp_call_tool",
            status: :failed,
            resource_uri: ref.resource_uri,
            tool_name: tool_name
          })

        {:ok, denied(config.server_id, tool_name, permission_decision, reason)}
    end
  end

  defp create_confirmation(
         config,
         tool_name,
         arguments,
         params,
         ref,
         context,
         permission_decision
       ) do
    summary = call_request_summary(config, tool_name, arguments, ref)

    attrs = %{
      origin: Origin.from_context(context, "mcp_call_tool"),
      target_action: %{name: "mcp_call_tool", module: inspect(__MODULE__)},
      target_permission: @permission,
      target_execution_mode: :mcp_tool_call,
      security_decision: permission_decision,
      source_signal_id: source_signal_id(context),
      source_trace_id: source_trace_id(context),
      runner_metadata: runner_metadata(context),
      params_summary: summary,
      resume_params_ref: resume_params(config, tool_name, arguments, params)
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        _audit =
          Audit.append(:mcp, :requested, config, permission_decision, %{
            action: "mcp_call_tool",
            status: :needs_confirmation,
            confirmation_id: confirmation_id(confirmation),
            resource_uri: ref.resource_uri,
            tool_name: tool_name,
            argument_keys: argument_keys(arguments)
          })

        {:ok,
         %{
           message: "MCP tool #{tool_name} for #{config.server_id} needs confirmation.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           server_id: config.server_id,
           tool_call: summary,
           confirmation: confirmation,
           confirmation_id: confirmation_id(confirmation),
           actions: [
             action(:needs_confirmation, permission_decision, %{
               server_id: config.server_id,
               tool_name: tool_name,
               resource_uri: ref.resource_uri,
               confirmation_id: confirmation_id(confirmation),
               argument_keys: argument_keys(arguments)
             })
             |> Map.put(:confirmation_metadata, confirmation_metadata(confirmation))
           ]
         }}

      {:error, reason} ->
        {:ok, denied(config.server_id, tool_name, permission_decision, reason)}
    end
  end

  defp denied(server_id, tool_name, permission_decision, reason) do
    %{
      message: "MCP tool call failed for #{server_id || "unknown"}: #{inspect(reason)}.",
      status: :denied,
      error: reason,
      permission_decision: permission_decision,
      server_id: server_id,
      tool_call: %{server_id: server_id, tool_name: tool_name},
      actions: [
        action(:denied, permission_decision, %{
          server_id: server_id,
          tool_name: tool_name,
          error: reason
        })
      ]
    }
  end

  defp server_enabled(%ServerConfig{enabled?: true}), do: :ok
  defp server_enabled(_config), do: {:error, :server_disabled}

  defp tool_allowed(%ServerConfig{} = config, tool_name) do
    cond do
      tool_name in config.tool_denylist ->
        {:error, :tool_denied}

      config.tool_allowlist != [] and tool_name not in config.tool_allowlist ->
        {:error, :tool_not_allowed}

      true ->
        :ok
    end
  end

  defp confirmation_allowed(%ServerConfig{confirmation: "denied"}), do: {:error, :tool_denied}
  defp confirmation_allowed(_config), do: :ok

  defp tool_ref(%ServerConfig{server_id: server_id}, tool_name, params)
       when is_binary(server_id) and is_binary(tool_name) and tool_name != "" do
    resource_uri = ResourceURI.mcp!(server_id, "tools/" <> tool_name)

    Ref.new(%{
      resource_uri: resource_uri,
      origin_kind: :mcp_resource,
      canonical_id: resource_uri,
      operation_class: :mcp_tool_call,
      access_mode: :call,
      scope: Scope.mcp_tool("#{server_id}:#{tool_name}"),
      downstream_consumer: downstream_consumer(params),
      metadata: %{server_id: server_id, tool_name: tool_name}
    })
  end

  defp tool_ref(_config, _tool_name, _params), do: {:error, :invalid_tool_name}

  defp call_request_summary(config, tool_name, arguments, ref) do
    %{
      server_id: config.server_id,
      tool_name: tool_name,
      resource_uri: ref.resource_uri,
      operation_class: :mcp_tool_call,
      arguments: argument_summary(arguments),
      resource_refs: [Ref.to_map(ref)]
    }
  end

  defp result_summary(config, tool_name, arguments, result, ref) do
    tool_result = Map.get(result, :result, %{})

    %{
      server_id: config.server_id,
      tool_name: tool_name,
      resource_uri: ref.resource_uri,
      argument_keys: argument_keys(arguments),
      result_keys: result_keys(tool_result),
      content_count: content_count(tool_result),
      is_error: truthy?(Map.get(tool_result, "isError") || Map.get(tool_result, :isError))
    }
  end

  defp resume_params(config, tool_name, arguments, params) do
    %{
      server_id: config.server_id,
      tool_name: tool_name,
      arguments: arguments,
      downstream_consumer: downstream_consumer(params),
      idempotency_key: field(params, :idempotency_key)
    }
    |> drop_nil_values()
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "mcp_call_tool",
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      execution: :mcp_tool_call,
      mcp_metadata: metadata
    }
  end

  defp argument_summary(arguments),
    do: %{key_count: map_size(arguments), keys: argument_keys(arguments)}

  defp argument_keys(arguments) when is_map(arguments) do
    arguments
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp result_keys(result) when is_map(result) do
    result
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp result_keys(_result), do: []

  defp content_count(%{"content" => content}) when is_list(content), do: length(content)
  defp content_count(%{content: content}) when is_list(content), do: length(content)
  defp content_count(_result), do: 0

  defp approved_resume?(context), do: get_in(context, [:confirmation, :approved?]) == true

  defp downstream_consumer(params), do: field(params, :downstream_consumer) || "mcp_tool_runner"

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

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
end
