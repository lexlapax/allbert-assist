defmodule AllbertAssist.Actions.Templates.RenderTemplate do
  @moduledoc """
  Registered read-only action for rendering reviewed v0.38 templates.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :template_render,
    skill_backed?: false,
    confirmation: :not_required,
    name: "render_template",
    description: "Render a reviewed template pattern without writing files.",
    category: "templates",
    tags: ["templates", "render", "read_only"],
    schema: [
      pattern_id: [type: :string, required: true],
      params: [type: :map, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      rendered: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Templates

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, rendered} <- Templates.render(pattern_id(params), template_params(params)) do
      {:ok,
       %{
         message: "Rendered #{rendered.pattern_id} template.",
         status: :completed,
         permission_decision: permission_decision,
         rendered: rendered_summary(rendered),
         actions: [action(:completed, permission_decision, %{pattern_id: rendered.pattern_id})]
       }}
    else
      false -> {:ok, denied(permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(permission_decision, reason)}
    end
  end

  def run(_params, context) do
    {:ok, denied(PermissionGate.authorize(:read_only, context), :invalid_params)}
  end

  defp rendered_summary(rendered) do
    %{
      pattern_id: rendered.pattern_id,
      params: rendered.params,
      target_shapes: rendered.target_shapes,
      live_integration?: rendered.live_integration?,
      files: Enum.map(rendered.files, &Map.take(&1, [:path, :bytes, :content]))
    }
  end

  defp pattern_id(params), do: Map.get(params, :pattern_id) || Map.get(params, "pattern_id")
  defp template_params(params), do: Map.get(params, :params) || Map.get(params, "params") || %{}

  defp denied(permission_decision, reason) do
    %{
      message: "Template render was denied or unavailable: #{inspect(reason)}",
      status: :denied,
      error: reason,
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "render_template",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      template_metadata: metadata
    }
  end
end
