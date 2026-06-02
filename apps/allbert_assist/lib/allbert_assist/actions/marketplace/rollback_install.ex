defmodule AllbertAssist.Actions.Marketplace.RollbackInstall do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :marketplace_install,
    exposure: :internal,
    execution_mode: :marketplace_rollback,
    skill_backed?: false,
    confirmation: :not_required,
    resumable?: true,
    name: "rollback_marketplace_install",
    description: "Rollback one installed Marketplace Lite bundle.",
    category: "marketplace",
    tags: ["marketplace", "rollback"],
    schema: [
      entry_id: [type: :string, required: true]
    ],
    output_schema: []

  alias AllbertAssist.Actions.Marketplace.Support
  alias AllbertAssist.Marketplace

  @impl true
  def run(params, context) do
    request = %{entry_id: Support.field(params, :entry_id, "")}

    Support.gated_write(name(), :marketplace_rollback, request, context, fn decision ->
      case Marketplace.rollback_install(request.entry_id) do
        {:ok, result} ->
          Support.completed(
            name(),
            :marketplace_install,
            decision,
            result,
            "Marketplace install rolled back."
          )

        {:error, diagnostic} ->
          Support.failed(name(), :marketplace_install, decision, diagnostic)
      end
    end)
  end
end
