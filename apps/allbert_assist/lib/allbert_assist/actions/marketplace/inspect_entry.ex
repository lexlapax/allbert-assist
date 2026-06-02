defmodule AllbertAssist.Actions.Marketplace.InspectEntry do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :marketplace_browse,
    skill_backed?: false,
    confirmation: :not_required,
    name: "inspect_marketplace_entry",
    description: "Inspect one Marketplace Lite catalog entry and bundle manifest.",
    category: "marketplace",
    tags: ["marketplace", "catalog", "read_only"],
    schema: [
      entry_id: [type: :string, required: true]
    ],
    output_schema: []

  alias AllbertAssist.Actions.Marketplace.Support
  alias AllbertAssist.Marketplace

  @impl true
  def run(params, context) do
    Support.read_only(name(), context, fn decision ->
      entry_id = Support.field(params, :entry_id, "")

      case Marketplace.inspect_entry(entry_id) do
        {:ok, result} ->
          Support.completed(name(), :read_only, decision, result, "Marketplace entry inspected.")

        {:error, diagnostic} ->
          Support.failed(name(), :read_only, decision, diagnostic)
      end
    end)
  end
end
