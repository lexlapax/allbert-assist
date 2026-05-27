defmodule AllbertAssist.Actions.Templates.ScaffoldTemplate do
  @moduledoc """
  Registered effectful action for writing inert developer template scaffolds.
  """

  use AllbertAssist.Action,
    permission: :skill_write,
    exposure: :internal,
    execution_mode: :template_scaffold,
    skill_backed?: false,
    confirmation: :not_required,
    name: "scaffold_template",
    description: "Write an inert developer scaffold from a reviewed template pattern.",
    category: "templates",
    tags: ["templates", "scaffold", "skill_write"],
    schema: [
      pattern_id: [type: :string, required: true],
      params: [type: :map, required: true],
      target: [type: :string, required: false],
      force?: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      scaffold: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Templates.Scaffold

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:skill_write, context)

    with :ok <- ensure_create_enabled(),
         true <- PermissionGate.allowed?(permission_decision),
         {:ok, scaffold} <-
           Scaffold.write(pattern_id(params), template_params(params), opts(params)) do
      {:ok,
       %{
         message: "Template scaffold #{scaffold.pattern_id} written to #{scaffold.target_root}.",
         status: :completed,
         permission_decision: permission_decision,
         scaffold: scaffold_summary(scaffold),
         actions: [action(:completed, permission_decision, scaffold_summary(scaffold))]
       }}
    else
      false -> {:ok, denied(permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(permission_decision, reason)}
    end
  end

  def run(_params, context) do
    {:ok, denied(PermissionGate.authorize(:skill_write, context), :invalid_params)}
  end

  defp ensure_create_enabled do
    case Settings.get("templates.create.enabled") do
      {:ok, true} -> :ok
      _other -> {:error, :template_create_disabled}
    end
  end

  defp scaffold_summary(scaffold) do
    %{
      pattern_id: scaffold.pattern_id,
      target_root: scaffold.target_root,
      live_integration?: scaffold.live_integration?,
      target_shapes: scaffold.target_shapes,
      files: Enum.map(scaffold.files, &Map.take(&1, [:path, :destination, :bytes]))
    }
  end

  defp opts(params) do
    []
    |> maybe_put(:target, Map.get(params, :target) || Map.get(params, "target"))
    |> maybe_put(:force?, Map.get(params, :force?) || Map.get(params, "force?"))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp pattern_id(params), do: Map.get(params, :pattern_id) || Map.get(params, "pattern_id")
  defp template_params(params), do: Map.get(params, :params) || Map.get(params, "params") || %{}

  defp denied(permission_decision, reason) do
    %{
      message: "Template scaffold was denied or unavailable: #{inspect(reason)}",
      status: :denied,
      error: reason,
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "scaffold_template",
      status: status,
      permission: :skill_write,
      permission_decision: permission_decision,
      template_metadata: metadata
    }
  end
end
