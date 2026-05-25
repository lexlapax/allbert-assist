defmodule AllbertAssist.Actions.DynamicPlugins.ListDynamicDrafts do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_dynamic_drafts",
    description: "List v0.37 dynamic draft metadata.",
    category: "dynamic_plugins",
    tags: ["dynamic_plugins", "drafts", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      drafts: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    if PermissionGate.allowed?(permission_decision) do
      drafts = DynamicPlugins.list_drafts()

      {:ok,
       %{
         message: message(drafts),
         status: :completed,
         drafts: drafts,
         actions: [action(:completed, permission_decision, %{draft_count: length(drafts)})]
       }}
    else
      {:ok,
       %{
         message: "Dynamic draft metadata is not available to this request.",
         status: :denied,
         error: :permission_denied,
         actions: [action(:denied, permission_decision, %{error: :permission_denied})]
       }}
    end
  end

  defp message([]), do: "No dynamic drafts found."
  defp message(drafts), do: "Dynamic drafts: #{length(drafts)}"

  defp action(status, permission_decision, metadata) do
    %{
      name: "list_dynamic_drafts",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      dynamic_plugins_metadata: metadata
    }
  end
end
