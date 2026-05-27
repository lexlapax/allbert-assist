defmodule AllbertAssist.Templates.Patterns.Tool do
  @moduledoc """
  Reviewed v0.38 LLM-tool/action scaffold pattern.

  The generated action shape is the only v0.38 template target that may later
  use the v0.36/v0.37 live-integration path. Developer scaffolds remain inert.
  """

  @behaviour AllbertAssist.Templates.Pattern

  alias AllbertAssist.Templates.Parameters

  @permissions ~w[read_only memory_write external_network]

  @impl true
  def id, do: "llm_tool"

  @impl true
  def label, do: "LLM tool"

  @impl true
  def description, do: "Reviewed dynamic action scaffold with bounded delegated effects."

  @impl true
  def parameter_schema do
    [
      %{name: "name", type: :string, required: true, min_length: 1, max_length: 64},
      %{
        name: "description",
        type: :string,
        default: "A reviewed Allbert LLM-tool action scaffold.",
        max_length: 240
      },
      %{
        name: "instruction",
        type: :string,
        default: "Return a concise, bounded response for the supplied text.",
        max_length: 500
      },
      %{name: "permission", type: :enum, default: "read_only", allowed_values: @permissions},
      %{name: "version", type: :string, default: "0.1.0", max_length: 32}
    ]
  end

  @impl true
  def files do
    [
      %{source: "tool/README.md.tmpl", target: "README.md"},
      %{source: "tool/dynamic_manifest.json.tmpl", target: "dynamic_manifest.json"},
      %{source: "tool/action.ex.tmpl", target: "source/lib/action.ex"},
      %{source: "tool/action_test.exs.tmpl", target: "source/test/action_test.exs"},
      %{source: "tool/delegated_effects.md.tmpl", target: "docs/delegated-effects.md"}
    ]
  end

  @impl true
  def target_shapes, do: ["action"]

  @impl true
  def live_integration?, do: true

  @impl true
  def validation_profile, do: "dynamic_action"

  @impl true
  def normalize_params(params) do
    slug = Map.fetch!(params, "slug")
    module_basename = Parameters.module_basename(slug)
    action_module = "AllbertAssist.DynamicPlugins.Generated.#{module_basename}.Action"
    test_module = "AllbertAssist.DynamicPlugins.Generated.#{module_basename}.ActionTest"
    action_name = "template_#{slug}"
    permission = Map.fetch!(params, "permission")
    description = Map.get(params, "description", "")
    instruction = Map.get(params, "instruction", "")
    version = Map.get(params, "version", "0.1.0")

    {:ok,
     params
     |> Map.put("pattern_id", id())
     |> Map.put("action_name", action_name)
     |> Map.put("action_module", action_module)
     |> Map.put("test_module", test_module)
     |> Map.put("compiled_path", compiled_path(slug))
     |> Map.put("test_compiled_path", test_compiled_path(slug))
     |> Map.put("permission", permission)
     |> Map.put("permission_atom", permission)
     |> Map.put("facade_name", facade_name(permission))
     |> Map.put("schema_fields", schema_fields(permission))
     |> Map.put("run_body", run_body(permission, action_name, instruction))
     |> Map.put("version", version)
     |> Map.put("json_action_name", Jason.encode!(action_name))
     |> Map.put("json_action_module", Jason.encode!(action_module))
     |> Map.put("json_test_module", Jason.encode!(test_module))
     |> Map.put("json_description", Jason.encode!(description))
     |> Map.put("json_permission", Jason.encode!(permission))
     |> Map.put("json_compiled_path", Jason.encode!(compiled_path(slug)))
     |> Map.put("json_test_compiled_path", Jason.encode!(test_compiled_path(slug)))
     |> Map.put("description_literal", inspect(description))
     |> Map.put("instruction_literal", inspect(instruction))}
  end

  defp compiled_path(slug) do
    "apps/allbert_assist/lib/allbert_assist/dynamic_plugins/generated/#{slug}/action.ex"
  end

  defp test_compiled_path(slug) do
    "apps/allbert_assist/test/allbert_assist/dynamic_plugins/generated/#{slug}/action_test.exs"
  end

  defp facade_name("memory_write"), do: "append_memory"
  defp facade_name("external_network"), do: "external_network_request"
  defp facade_name(_permission), do: "none"

  defp schema_fields("memory_write") do
    """
        text: [type: :string, required: false, doc: "Input text to summarize before memory append."],
        memory: [type: :string, required: false, doc: "Memory text to append."],
        source_text: [type: :string, required: false, doc: "Original request text."]
    """
  end

  defp schema_fields("external_network") do
    """
        text: [type: :string, required: false, doc: "Input text for the request rationale."],
        url: [type: :string, required: false, doc: "Absolute HTTP(S) URL to request."],
        request: [type: :string, required: false, doc: "Human-readable network request."],
        source_text: [type: :string, required: false, doc: "Original request text."]
    """
  end

  defp schema_fields(_permission) do
    """
        text: [type: :string, required: false, doc: "Input text for the tool."]
    """
  end

  defp run_body("memory_write", _action_name, _instruction) do
    """
        memory = Map.get(params, :memory) || Map.get(params, :text) || ""

        delegate_params = %{
          memory: memory,
          source_text: Map.get(params, :source_text)
        }

        AllbertAssist.DynamicPlugins.Delegate.run("append_memory", delegate_params, context)
    """
  end

  defp run_body("external_network", _action_name, _instruction) do
    """
        url = Map.get(params, :url, "https://example.com/")

        delegate_params = %{
          url: url,
          request: Map.get(params, :request, "Fetch a reviewed external resource."),
          source_text: Map.get(params, :source_text)
        }

        AllbertAssist.DynamicPlugins.Delegate.run("external_network_request", delegate_params, context)
    """
  end

  defp run_body(_permission, action_name, instruction) do
    """
        _ = context
        text = Map.get(params, :text, "")
        message = String.trim(text)

        message =
          if message == "" do
            #{inspect(instruction)}
          else
            message
          end

        {:ok,
         %{
           message: message,
           status: :completed,
           actions: [
             %{
               name: #{inspect(action_name)},
               status: :completed,
               permission: :read_only
             }
           ]
         }}
    """
  end
end
