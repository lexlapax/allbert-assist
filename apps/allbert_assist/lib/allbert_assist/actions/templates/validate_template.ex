defmodule AllbertAssist.Actions.Templates.ValidateTemplate do
  @moduledoc """
  Registered read-only action for validating reviewed template inputs.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :template_validate,
    skill_backed?: false,
    confirmation: :not_required,
    name: "validate_template",
    description: "Validate a reviewed template pattern and output mode.",
    category: "templates",
    tags: ["templates", "validate", "read_only"],
    schema: [
      pattern_id: [type: :string, required: true],
      params: [type: :map, required: true],
      mode: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      validation: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Templates.Scaffold

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, preview} <- Scaffold.preview(pattern_id(params), template_params(params)),
         :ok <- validate_mode(preview, mode(params)) do
      validation = %{
        pattern_id: preview.pattern_id,
        target_shapes: preview.target_shapes,
        live_integration?: preview.live_integration?,
        target_root: preview.target_root,
        existing?: preview.existing?,
        files: Enum.map(preview.files, &Map.take(&1, [:path, :bytes, :status])),
        mode: mode(params)
      }

      {:ok,
       %{
         message: "Template #{preview.pattern_id} is ready.",
         status: :completed,
         permission_decision: permission_decision,
         validation: validation,
         actions: [action(:completed, permission_decision, validation)]
       }}
    else
      false -> {:ok, denied(permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(permission_decision, reason)}
    end
  end

  def run(_params, context) do
    {:ok, denied(PermissionGate.authorize(:read_only, context), :invalid_params)}
  end

  defp validate_mode(%{live_integration?: true}, "live_integration"), do: :ok

  defp validate_mode(%{live_integration?: false, pattern_id: id}, "live_integration") do
    {:error, {:unsupported_live_integration_pattern, id}}
  end

  defp validate_mode(_preview, _mode), do: :ok

  defp pattern_id(params), do: Map.get(params, :pattern_id) || Map.get(params, "pattern_id")
  defp template_params(params), do: Map.get(params, :params) || Map.get(params, "params") || %{}
  defp mode(params), do: Map.get(params, :mode) || Map.get(params, "mode") || "developer_scaffold"

  defp denied(permission_decision, reason) do
    %{
      message: "Template validation was denied or unavailable: #{inspect(reason)}",
      status: :denied,
      error: reason,
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "validate_template",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      template_metadata: metadata
    }
  end
end
