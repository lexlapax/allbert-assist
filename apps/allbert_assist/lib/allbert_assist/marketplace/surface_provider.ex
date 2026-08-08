defmodule AllbertAssist.Marketplace.SurfaceProvider do
  @moduledoc """
  Workspace surface provider metadata for Marketplace Lite.
  """

  use AllbertAssist.App.SurfaceProvider

  alias AllbertAssist.Marketplace.Panels.Catalog
  alias AllbertAssist.Surface

  @spec surfaces() :: [Surface.t()]
  def surfaces, do: [static_catalog_surface()]

  @doc false
  @spec static_catalog_surface() :: Surface.t()
  def static_catalog_surface, do: build_catalog_surface(Catalog.static_node())

  @spec workspace_panel_surfaces(map()) :: [Surface.t()]
  def workspace_panel_surfaces(context) when is_map(context), do: [catalog_surface(context)]

  def surface_catalog, do: []

  @spec catalog_surface(map()) :: Surface.t()
  def catalog_surface(context \\ %{}) when is_map(context) do
    build_catalog_surface(Catalog.node(context))
  end

  defp build_catalog_surface(catalog_node) do
    %Surface{
      id: :marketplace_catalog_panel,
      app_id: :allbert,
      label: "Marketplace",
      path: "/workspace",
      kind: :panel,
      zone: :canvas_panels,
      status: :available,
      nodes: [catalog_node],
      fallback_text: "Marketplace catalog is available in the workspace.",
      metadata: %{visible_when: :operator_opened, order: 12}
    }
  end

  def intent_descriptors do
    # CoreApp owns the effective install descriptor. A second descriptor for
    # the same {app_id, action_name} was never observable because the legacy
    # registry kept the first match; retaining it would make Pack capture
    # depend on silent conflict resolution.
    [
      %{
        app_id: :allbert,
        action_name: "list_marketplace_entries",
        label: "Browse reviewed marketplace catalog",
        destination: "workspace:marketplace",
        examples: [
          "show me the reviewed skill catalog",
          "show me reviewed templates",
          "what's in the marketplace"
        ],
        synonyms: ["marketplace", "reviewed skills", "reviewed templates"],
        required_slots: [],
        handoff_required?: false
      },
      %{
        app_id: :allbert,
        action_name: "list_installed_marketplace_bundles",
        label: "List installed marketplace bundles",
        destination: "workspace:marketplace",
        examples: ["show me installed marketplace skills"],
        synonyms: ["installed marketplace", "installed reviewed skills"],
        required_slots: [],
        handoff_required?: false
      },
      %{
        app_id: :allbert,
        action_name: "rollback_marketplace_install",
        label: "Rollback marketplace install",
        destination: "workspace:marketplace",
        examples: ["rollback allbert/research-helpers"],
        synonyms: ["rollback marketplace install"],
        required_slots: [],
        handoff_required?: false
      },
      %{
        app_id: :allbert,
        action_name: "verify_marketplace_bundle_hash",
        label: "Verify marketplace bundle hash",
        destination: "workspace:marketplace",
        examples: ["verify allbert/research-helpers"],
        synonyms: ["verify marketplace bundle", "verify reviewed bundle"],
        required_slots: [],
        handoff_required?: false
      }
    ]
  end
end
