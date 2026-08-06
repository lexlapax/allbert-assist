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
    message = "Model catalog has #{length(entries)} matching entries."

    {:ok,
     %{
       message: message,
       model_payload: "Model catalog listing.",
       surface_payload: render(catalog.version, catalog.roles, entries),
       status: PermissionGate.response_status(decision),
       version: catalog.version,
       roles: catalog.roles,
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

  defp render(version, roles, entries) do
    ["Model catalog v#{version}:" | render_roles(roles) ++ Enum.map(entries, &render_entry/1)]
    |> Enum.join("\n")
  end

  defp render_roles(roles) do
    ["Model roles:" | Enum.map(roles, &render_role/1)]
  end

  defp render_role(%{status: :unconfigured} = role),
    do: "- #{role.reference}: unconfigured key=#{role.settings_key}"

  defp render_role(role),
    do: "- #{role.reference}: assigned=#{role.profile} key=#{role.settings_key}"

  defp render_entry(entry) do
    readiness = catalog_readiness(entry)
    floor = if entry.floor_gb, do: " floor=#{entry.floor_gb}GB", else: ""

    "- #{entry.id}: source=#{entry.source} " <>
      "purposes=#{Enum.join(entry.purposes, ",")}#{assigned_roles(entry)}#{floor}#{readiness}"
  end

  defp assigned_roles(%{assigned_roles: []}), do: ""
  defp assigned_roles(entry), do: " assigned_roles=#{Enum.join(entry.assigned_roles, ",")}"

  defp catalog_readiness(%{status: :ready}), do: " ready"
  defp catalog_readiness(%{status: :not_pulled}), do: " not-pulled"
  defp catalog_readiness(%{status: :configured}), do: " configured"
  defp catalog_readiness(_entry), do: ""

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
