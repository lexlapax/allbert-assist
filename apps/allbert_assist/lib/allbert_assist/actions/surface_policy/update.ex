defmodule AllbertAssist.Actions.SurfacePolicy.Update do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :settings_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "surface_policy_update",
    description: "Update one surface policy setting through Settings Central.",
    category: "settings",
    tags: ["settings", "surface_policy", "write", "operator"],
    schema: [
      surface: [type: :string, required: true],
      action: [type: :string, required: true],
      field: [type: :string, required: true],
      value: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      surface_policy: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Maps
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.SurfacePolicy

  @fields ~w(render_mode redaction_profile max_rows raw_requires_affordance)

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)
    surface = normalize_segment(Maps.field(params, :surface))
    action = normalize_segment(Maps.field(params, :action))
    policy_field = Maps.field(params, :field)
    value = parse_value(policy_field, Maps.field(params, :value))

    with true <- PermissionGate.allowed?(permission_decision),
         :ok <- validate_field(policy_field),
         key <- "surface_policy.surfaces.#{surface}.#{action}.#{policy_field}",
         {:ok, setting} <- Settings.put(key, value, action_context(context, permission_decision)),
         {:ok, policy} <- SurfacePolicy.dto(%{surface: surface, action: action}, context) do
      {:ok, completed(setting, policy, permission_decision)}
    else
      false ->
        {:ok, denied(surface, action, policy_field, permission_decision, :permission_denied)}

      {:error, reason} ->
        {:ok, denied(surface, action, policy_field, permission_decision, reason)}
    end
  end

  defp completed(setting, policy, permission_decision) do
    %{
      message: "Updated #{setting.key} to #{inspect(setting.value)}.",
      status: :completed,
      permission_decision: permission_decision,
      setting: setting,
      surface_policy: policy,
      actions: [
        action(:completed, permission_decision, %{
          setting_key: setting.key,
          audit_path: audit_path(setting.diagnostics)
        })
      ]
    }
  end

  defp denied(surface, action_name, policy_field, permission_decision, reason) do
    %{
      message:
        "I could not update surface policy #{surface}/#{action_name}/#{policy_field}: #{inspect(reason)}",
      status: :denied,
      permission_decision: permission_decision,
      actions: [
        action(:denied, permission_decision, %{
          surface: surface,
          action_name: action_name,
          field: policy_field,
          error: reason
        })
      ]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "surface_policy_update",
      status: status,
      permission: :settings_write,
      permission_decision: permission_decision,
      settings_metadata: metadata
    }
  end

  defp validate_field(field) when field in @fields, do: :ok
  defp validate_field(field), do: {:error, {:invalid_surface_policy_field, field}}

  defp parse_value("max_rows", value) when is_integer(value), do: value

  defp parse_value("max_rows", value) do
    case Integer.parse(to_string(value)) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp parse_value("raw_requires_affordance", value) when value in [true, false], do: value
  defp parse_value("raw_requires_affordance", "true"), do: true
  defp parse_value("raw_requires_affordance", "false"), do: false
  defp parse_value(_field, value), do: value

  defp normalize_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-z0-9_]/, "_")
  end

  defp action_context(context, permission_decision) do
    request_context = Map.get(context, :request, context)

    request_context
    |> Map.take([:actor, :operator_id, :channel, :input_signal_id])
    |> Map.new(fn
      {:operator_id, value} -> {:actor, value}
      {:input_signal_id, value} -> {:source_signal_id, value}
      other -> other
    end)
    |> Map.put(:permission_decision, permission_decision)
  end

  defp audit_path(diagnostics) do
    diagnostics
    |> Enum.find_value(&Map.get(&1, :audit_path))
  end
end
