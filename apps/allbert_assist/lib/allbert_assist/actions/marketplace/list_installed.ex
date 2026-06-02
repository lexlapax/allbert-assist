defmodule AllbertAssist.Actions.Marketplace.ListInstalled do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :marketplace_browse,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_installed_marketplace_bundles",
    description: "List installed Marketplace Lite bundles.",
    category: "marketplace",
    tags: ["marketplace", "installed", "read_only"],
    schema: [],
    output_schema: []

  alias AllbertAssist.Actions.Marketplace.Support
  alias AllbertAssist.Marketplace

  @impl true
  def run(_params, context) do
    Support.read_only(name(), context, fn decision ->
      case Marketplace.list_installed() do
        {:ok, installed} ->
          Support.completed(
            name(),
            :read_only,
            decision,
            %{installed: installed},
            "Marketplace installs listed."
          )

        {:error, diagnostic} ->
          Support.failed(name(), :read_only, decision, diagnostic)
      end
    end)
  end
end
