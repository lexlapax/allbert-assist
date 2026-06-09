defmodule AllbertAssist.PublicProtocol.Mcp.Runtime do
  @moduledoc """
  Testable MCP surface runtime for the v0.51 public MCP server.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.PublicProtocol.ExposureFilter
  alias AllbertAssist.PublicProtocol.Mcp.Schema
  alias AllbertAssist.PublicProtocol.ResultReadback
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Runtime.Response, as: RuntimeResponse
  alias AllbertAssist.Settings

  @stdio_surface "mcp_stdio"
  @http_surface "mcp_http"
  @default_client_id "stdio-client"
  @resource_scheme "allbert-memory"

  @type resource :: %{
          required(:uri) => String.t(),
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:mime_type) => String.t(),
          required(:namespace) => map()
        }

  @spec surface_enabled?(String.t()) :: boolean()
  def surface_enabled?(surface \\ @stdio_surface)

  def surface_enabled?(@stdio_surface) do
    enabled?("mcp_server.enabled") and enabled?("mcp_server.stdio.enabled")
  end

  def surface_enabled?(@http_surface) do
    enabled?("mcp_server.enabled") and enabled?("mcp_server.streamable_http.enabled")
  end

  def surface_enabled?(_surface), do: false

  @spec enabled_tools(String.t()) :: {:ok, [Capability.t()]} | {:error, term()}
  def enabled_tools(surface \\ @stdio_surface) do
    surface = normalize_surface(surface)

    if surface_enabled?(surface) do
      with {:ok, allowlist} <- Settings.get("mcp_server.tools_enabled") do
        ExposureFilter.filter_tools(allowlist)
      end
    else
      {:ok, []}
    end
  end

  @spec enabled_resources(String.t()) :: {:ok, [resource()]} | {:error, term()}
  def enabled_resources(surface \\ @stdio_surface) do
    surface = normalize_surface(surface)

    if surface_enabled?(surface) do
      with {:ok, allowlist} <- Settings.get("mcp_server.memory_namespaces_enabled"),
           {:ok, namespaces} <- ExposureFilter.filter_memory_namespaces(allowlist) do
        {:ok, Enum.map(namespaces, &resource_from_namespace/1)}
      end
    else
      {:ok, []}
    end
  end

  @spec tool_specs(String.t()) :: {:ok, [{String.t(), keyword()}]} | {:error, term()}
  def tool_specs(surface \\ @stdio_surface) do
    with {:ok, tools} <- enabled_tools(surface) do
      {:ok, Enum.map(tools, &{&1.name, Schema.tool_definition(&1)})}
    end
  end

  @spec resource_specs(String.t()) :: {:ok, [{String.t(), keyword()}]} | {:error, term()}
  def resource_specs(surface \\ @stdio_surface) do
    with {:ok, resources} <- enabled_resources(surface) do
      {:ok,
       Enum.map(resources, fn resource ->
         {resource.uri,
          [
            name: resource.name,
            description: resource.description,
            mime_type: resource.mime_type
          ]}
       end)}
    end
  end

  @spec call_tool(String.t(), map(), map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def call_tool(name, params, context, surface \\ nil)

  def call_tool(name, params, context, surface) when is_binary(name) and is_map(params) do
    surface = normalize_surface(surface || context_surface(context))

    with {:ok, tools} <- enabled_tools(surface),
         {:ok, capability} <- fetch_tool(tools, name),
         {:ok, response} <- Runner.run(name, params, runner_context(context, capability, surface)) do
      response_to_payload(response, name, context, surface)
    end
  end

  @spec read_resource(String.t(), map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def read_resource(uri, context, surface \\ nil)

  def read_resource(uri, context, surface) when is_binary(uri) do
    surface = normalize_surface(surface || context_surface(context))

    with {:ok, resources} <- enabled_resources(surface),
         {:ok, resource} <- fetch_resource(resources, uri) do
      {:ok,
       %{
         "uri" => resource.uri,
         "name" => resource.name,
         "description" => resource.description,
         "surface" => surface,
         "resource_type" => "app_memory_namespace",
         "app_id" => atom_to_string(resource.namespace.app_id),
         "namespace" => atom_to_string(resource.namespace.namespace),
         "writable" => Map.get(resource.namespace, :writable, false)
       }}
    end
  end

  @spec client_id(map()) :: String.t()
  def client_id(context) when is_map(context) do
    context
    |> get_in([:public_protocol, :client_id])
    |> normalize_client_id()
  end

  def client_id(_context), do: @default_client_id

  def resource_uri(%{app_id: app_id, namespace: namespace}) do
    "#{@resource_scheme}://#{atom_to_string(app_id)}/#{atom_to_string(namespace)}"
  end

  defp response_to_payload(response, name, context, surface) do
    case RuntimeResponse.status(response) do
      :needs_confirmation ->
        pending_payload(response, name, context, surface)

      :denied ->
        {:ok,
         %{
           status: "denied",
           message: Map.get(response, :message, "Action was denied."),
           error: Redactor.redact(Map.get(response, :error))
         }}

      status when status in [:error, :failed, :unsupported, :unavailable] ->
        {:ok,
         %{
           status: Atom.to_string(status),
           message: Map.get(response, :message, "Action failed."),
           error: Redactor.redact(Map.get(response, :error))
         }}

      _status ->
        {:ok,
         response
         |> Redactor.redact()
         |> Map.drop([:confirmation, :approval_handoff])}
    end
  end

  defp pending_payload(response, name, context, surface) do
    confirmation_id = confirmation_id(response)

    attrs = %{
      surface: surface,
      client_id: client_id(context),
      action_label: name,
      confirmation_id: confirmation_id,
      trace_id: trace_id(response),
      trace_metadata: trace_metadata(response)
    }

    with {:ok, call_result} <- ResultReadback.create(attrs) do
      {:ok,
       %{
         status: "confirmation_pending",
         message: Map.get(response, :message, "Action needs operator confirmation."),
         confirmation_id: confirmation_id,
         public_call_id: call_result.id
       }}
    end
  end

  defp runner_context(context, %Capability{} = capability, surface) do
    public_protocol =
      context
      |> Map.get(:public_protocol, %{})
      |> Map.merge(%{surface: surface, client_id: client_id(context)})

    context
    |> Map.put(:surface, surface)
    |> Map.put(:channel, channel_for_surface(surface))
    |> Map.put(:public_protocol, public_protocol)
    |> Map.put(:action_capability, Capability.summary(capability))
  end

  defp fetch_tool(tools, name) do
    case Enum.find(tools, &(&1.name == name)) do
      nil -> {:error, {:tool_not_exposed, name}}
      capability -> {:ok, capability}
    end
  end

  defp fetch_resource(resources, uri) do
    case Enum.find(resources, &(&1.uri == uri)) do
      nil -> {:error, {:resource_not_exposed, uri}}
      resource -> {:ok, resource}
    end
  end

  defp resource_from_namespace(namespace) do
    app_id = atom_to_string(namespace.app_id)
    name = atom_to_string(namespace.namespace)

    %{
      uri: resource_uri(namespace),
      name: "#{app_id}.#{name}",
      description: Map.get(namespace, :description, "#{app_id} #{name} memory namespace."),
      mime_type: "application/json",
      namespace: namespace
    }
  end

  defp enabled?(key) do
    case Settings.get(key) do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp context_surface(%{public_protocol: %{surface: surface}}), do: surface
  defp context_surface(%{public_protocol: %{"surface" => surface}}), do: surface
  defp context_surface(_context), do: @stdio_surface

  defp normalize_surface(@stdio_surface), do: @stdio_surface
  defp normalize_surface(@http_surface), do: @http_surface
  defp normalize_surface(_surface), do: @stdio_surface

  defp channel_for_surface(@http_surface), do: :mcp_http
  defp channel_for_surface(_surface), do: :mcp_stdio

  defp confirmation_id(%{confirmation_id: id}) when is_binary(id), do: id
  defp confirmation_id(%{"confirmation_id" => id}) when is_binary(id), do: id

  defp confirmation_id(%{approval_handoff: %{confirmation_id: id}}) when is_binary(id), do: id

  defp confirmation_id(%{"approval_handoff" => %{"confirmation_id" => id}}) when is_binary(id),
    do: id

  defp confirmation_id(%{actions: actions}) when is_list(actions),
    do: Enum.find_value(actions, &confirmation_id/1)

  defp confirmation_id(_response), do: nil

  defp trace_id(%{runner_metadata: %{completed_signal_id: id}}) when is_binary(id), do: id
  defp trace_id(%{runner_metadata: %{requested_signal_id: id}}) when is_binary(id), do: id
  defp trace_id(_response), do: nil

  defp trace_metadata(%{runner_metadata: metadata}) when is_map(metadata),
    do: Redactor.redact(Map.take(metadata, [:action_name, :status, :duration_ms]))

  defp trace_metadata(_response), do: %{}

  defp normalize_client_id(id) when is_binary(id) and id != "", do: id
  defp normalize_client_id(_id), do: @default_client_id

  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value) when is_binary(value), do: value
  defp atom_to_string(value), do: to_string(value)
end
