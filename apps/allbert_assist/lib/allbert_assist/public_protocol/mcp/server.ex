defmodule AllbertAssist.PublicProtocol.Mcp.Server do
  @moduledoc """
  v0.51 public MCP stdio server.

  Hermes is used for MCP framing and lifecycle callbacks only. HTTP ingress for
  MCP is added separately through Allbert-owned Plug/Phoenix request handling so
  it can enforce body caps, token authentication, rate limits, headers, and
  protocol-version denial before runtime work.
  """

  alias AllbertAssist.App.CoreApp
  alias AllbertAssist.PublicProtocol.Mcp.ProtocolVersions
  alias AllbertAssist.PublicProtocol.Mcp.Runtime
  alias Hermes.MCP.Error
  alias Hermes.Server.Frame
  alias Hermes.Server.Response

  use Hermes.Server,
    name: "allbert-assist",
    version: CoreApp.version(),
    capabilities: [:tools, :resources],
    protocol_versions: ProtocolVersions.supported()

  @impl true
  def init(client_info, frame) do
    frame =
      frame
      |> Frame.assign(:public_protocol_client_id, client_id(client_info))
      |> register_tools()
      |> register_resources()

    {:ok, frame}
  end

  @impl true
  def handle_tool_call(name, arguments, frame) do
    context = context(frame)

    case Runtime.call_tool(name, arguments, context) do
      {:ok, payload} ->
        {:reply, Response.json(Response.tool(), payload), frame}

      {:error, reason} ->
        {:reply, Response.error(Response.tool(), error_message(reason)), frame}
    end
  end

  @impl true
  def handle_resource_read(uri, frame) do
    case Runtime.read_resource(uri, context(frame)) do
      {:ok, payload} ->
        {:reply, Response.json(Response.resource(), payload), frame}

      {:error, reason} ->
        {:error, Error.resource(:not_found, %{message: error_message(reason)}), frame}
    end
  end

  @doc "Allbert-owned validation helper for ingress layers and tests."
  @spec validate_protocol_version(term()) :: ProtocolVersions.validation_result()
  def validate_protocol_version(version), do: ProtocolVersions.validate(version)

  defp register_tools(frame) do
    case Runtime.tool_specs() do
      {:ok, specs} ->
        Enum.reduce(specs, frame, fn {name, opts}, acc ->
          Frame.register_tool(acc, name, opts)
        end)

      {:error, _reason} ->
        frame
    end
  end

  defp register_resources(frame) do
    case Runtime.resource_specs() do
      {:ok, specs} ->
        Enum.reduce(specs, frame, fn {uri, opts}, acc ->
          Frame.register_resource(acc, uri, opts)
        end)

      {:error, _reason} ->
        frame
    end
  end

  defp context(frame) do
    client_id =
      Map.get(frame.assigns, :public_protocol_client_id) ||
        get_in(frame.private, [:client_info, "name"]) ||
        get_in(frame.private, [:client_info, :name]) ||
        "stdio-client"

    %{
      public_protocol: %{surface: "mcp_stdio", client_id: client_id},
      request: %{
        channel: :mcp_stdio,
        operator_id: "public-protocol:#{client_id}"
      }
    }
  end

  defp client_id(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp client_id(%{name: name}) when is_binary(name) and name != "", do: name
  defp client_id(_client_info), do: "stdio-client"

  defp error_message({:tool_not_exposed, name}), do: "Tool is not exposed: #{name}."
  defp error_message({:resource_not_exposed, uri}), do: "Resource is not exposed: #{uri}."
  defp error_message(reason), do: "MCP request failed: #{inspect(reason)}."
end
