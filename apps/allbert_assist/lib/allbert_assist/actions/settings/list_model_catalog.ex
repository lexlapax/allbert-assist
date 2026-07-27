defmodule AllbertAssist.Actions.Settings.ListModelCatalog do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_model_catalog",
    description: "List the merged redacted model catalog without hosted egress.",
    category: "settings",
    tags: ["settings", "models", "catalog", "read_only"],
    schema: [purpose: [type: :string, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Models.Catalog
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    decision = PermissionGate.authorize(:read_only, context)
    {:ok, catalog} = Catalog.list()
    purpose = field(params, :purpose)
    entries = filter_purpose(catalog.entries, purpose)

    {:ok,
     %{
       message: "Model catalog has #{length(entries)} matching entries.",
       status: PermissionGate.response_status(decision),
       version: catalog.version,
       entries: entries,
       diagnostics: catalog.diagnostics,
       actions: [
         %{
           name: name(),
           status: :completed,
           permission: :read_only,
           permission_decision: decision
         }
       ]
     }}
  end

  defp filter_purpose(entries, purpose) when is_binary(purpose) and purpose != "",
    do: Enum.filter(entries, &(purpose in &1.purposes))

  defp filter_purpose(entries, _purpose), do: entries

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
