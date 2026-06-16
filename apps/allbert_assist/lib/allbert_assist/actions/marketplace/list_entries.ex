defmodule AllbertAssist.Actions.Marketplace.ListEntries do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :marketplace_browse,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_marketplace_entries",
    description: "List shipped Marketplace Lite catalog entries.",
    category: "marketplace",
    tags: ["marketplace", "catalog", "read_only"],
    schema: [
      kind: [type: :string, required: false],
      installed_only: [type: :boolean, required: false]
    ],
    output_schema: []

  alias AllbertAssist.Actions.Marketplace.Support
  alias AllbertAssist.Marketplace

  @impl true
  def run(params, context) do
    Support.read_only(name(), context, fn decision ->
      with {:ok, entries} <- Marketplace.list_entries(),
           {:ok, installed} <- Marketplace.list_installed() do
        entries =
          entries
          |> filter_kind(Support.field(params, :kind))
          |> filter_installed(Support.field(params, :installed_only, false), installed)

        Support.completed(
          name(),
          :read_only,
          decision,
          %{entries: entries},
          "Marketplace entries listed."
        )
      else
        {:error, diagnostic} -> Support.failed(name(), :read_only, decision, diagnostic)
      end
    end)
  end

  defp filter_kind(entries, kind) when is_binary(kind) and kind != "",
    do: Enum.filter(entries, &(&1["kind"] == kind))

  defp filter_kind(entries, _kind), do: entries

  defp filter_installed(entries, true, installed) do
    installed_ids = MapSet.new(installed, & &1["entry_id"])
    Enum.filter(entries, &MapSet.member?(installed_ids, &1["id"]))
  end

  defp filter_installed(entries, _installed_only, _installed), do: entries
end
