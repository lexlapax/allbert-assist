defmodule AllbertAssist.Marketplace.SurfaceProvider do
  @moduledoc """
  Workspace surface provider metadata for Marketplace Lite.
  """

  use AllbertAssist.App.SurfaceProvider

  alias AllbertAssist.Marketplace.Panels.Catalog
  alias AllbertAssist.Surface

  @spec surfaces() :: [Surface.t()]
  def surfaces, do: [catalog_surface(%{})]

  @spec workspace_panel_surfaces(map()) :: [Surface.t()]
  def workspace_panel_surfaces(context) when is_map(context), do: [catalog_surface(context)]

  def surface_catalog, do: []

  @spec catalog_surface(map()) :: Surface.t()
  def catalog_surface(context \\ %{}) when is_map(context) do
    %Surface{
      id: :marketplace_catalog_panel,
      app_id: :allbert,
      label: "Marketplace",
      path: "/workspace",
      kind: :panel,
      zone: :canvas_panels,
      status: :available,
      nodes: [Catalog.node(context)],
      fallback_text: "Marketplace catalog is available in the workspace.",
      metadata: %{visible_when: :operator_opened, order: 12}
    }
  end

  def intent_descriptors do
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
        action_name: "install_marketplace_bundle",
        label: "Install reviewed marketplace bundle",
        destination: "workspace:marketplace",
        examples: ["install the allbert/research-helpers skill"],
        synonyms: ["install marketplace skill", "install reviewed bundle"],
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
