defmodule AllbertAssist.Actions.Settings.ListModelProfiles do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_model_profiles",
    description: "List model profiles with redacted credential status.",
    category: "settings",
    tags: ["settings", "models", "read_only"],
    schema: [render_mode: [type: :string, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    render_mode = render_mode(params, context)
    {:ok, models} = Settings.list_model_profiles()

    {:ok,
     %{
       message: message(models, render_mode),
       status: PermissionGate.response_status(permission_decision),
       models: models,
       actions: [
         %{
           name: "list_model_profiles",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision,
           settings_metadata: %{model_count: length(models), render_mode: render_mode}
         }
       ]
     }}
  end

  defp message(models, :operator_report) do
    rendered =
      models
      |> Enum.map(
        &"- #{&1.name}: provider=#{&1.provider}, endpoint_kind=#{&1.provider_endpoint_kind}, model=#{&1.model}, credential=#{&1.credential_status}"
      )
      |> Enum.join("\n")

    "Model profiles:\n\n#{rendered}"
  end

  defp message(models, :assistant_summary) do
    total = length(models)

    "Model registry has #{total} profiles loaded. I can discuss model setup safely here, " <>
      "but I won't dump the full operator report in chat. Use `/models` for the TUI " <>
      "model doctor or `mix allbert.model list` for the full operator report."
  end

  defp render_mode(params, context) do
    case field(params, :render_mode) || field(params, :mode) || field(context, :render_mode) do
      value when value in [:operator_report, "operator_report", :raw, "raw"] -> :operator_report
      _other -> :assistant_summary
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end
