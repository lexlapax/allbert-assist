defmodule AllbertAssist.PublicProtocol.Mcp.Schema do
  @moduledoc """
  Converts registered Allbert action metadata into MCP tool schemas.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Serialization
  alias Jido.Action.Schema, as: JidoSchema

  @empty_object %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @spec tool_definition(Capability.t()) :: keyword()
  def tool_definition(%Capability{} = capability) do
    module = capability.module

    [
      description: module.description(),
      input_schema: input_schema(module),
      annotations: annotations(capability)
    ]
  end

  @spec input_schema(module()) :: map()
  def input_schema(module) when is_atom(module) do
    if function_exported?(module, :schema, 0) do
      module.schema()
      |> JidoSchema.to_json_schema(strict: true)
      |> normalize_schema()
    else
      @empty_object
    end
  rescue
    _exception -> @empty_object
  end

  defp normalize_schema(schema) when is_map(schema) do
    schema
    |> Serialization.stringify_keys()
    |> Map.put_new("type", "object")
    |> Map.put_new("properties", %{})
    |> Map.put_new("additionalProperties", false)
  end

  defp annotations(%Capability{} = capability) do
    %{
      "readOnlyHint" => read_only?(capability),
      "destructiveHint" => not read_only?(capability),
      "idempotentHint" => read_only?(capability),
      "openWorldHint" => open_world?(capability)
    }
  end

  defp read_only?(%Capability{permission: :read_only, execution_mode: :read_only}), do: true
  defp read_only?(_capability), do: false

  defp open_world?(%Capability{execution_mode: :req_http}), do: true
  defp open_world?(%Capability{execution_mode: :mcp_tool_call}), do: true
  defp open_world?(_capability), do: false
end
