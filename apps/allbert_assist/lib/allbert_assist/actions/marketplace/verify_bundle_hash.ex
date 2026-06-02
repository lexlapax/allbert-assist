defmodule AllbertAssist.Actions.Marketplace.VerifyBundleHash do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :marketplace_browse,
    skill_backed?: false,
    confirmation: :not_required,
    name: "verify_marketplace_bundle_hash",
    description: "Verify one Marketplace Lite bundle hash.",
    category: "marketplace",
    tags: ["marketplace", "hash", "read_only"],
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

      case Marketplace.verify_bundle_hash(entry_id) do
        {:ok, result} ->
          Support.completed(
            name(),
            :read_only,
            decision,
            result,
            "Marketplace bundle hash verified."
          )

        {:error, diagnostic} ->
          Support.failed(name(), :read_only, decision, diagnostic)
      end
    end)
  end
end
