defmodule AllbertAssistWeb.Skeleton.RouteManifest do
  @moduledoc """
  v0.60 preview route manifest copied from `docs/design/information-architecture.md`.

  The walking-skeleton test compares this module row-for-row with the docs table
  before route smoke can pass.
  """

  alias AllbertAssist.Surface.Catalog

  @routes [
    %{
      route_id: :launch,
      preview_path: "/preview",
      title: "Launch and resume",
      nav_group: "start",
      active_key: "start_launch",
      catalog_components: [:workspace_shell, :nav_rail, :empty_state, :status_badge, :button]
    },
    %{
      route_id: :onboarding,
      preview_path: "/preview/onboarding",
      title: "Onboarding",
      nav_group: "start",
      active_key: "start_onboarding",
      catalog_components: [
        :workspace_shell,
        :nav_rail,
        :onboarding_panel,
        :models_panel,
        :status_badge
      ]
    },
    %{
      route_id: :workspace,
      preview_path: "/preview/workspace",
      title: "Workspace",
      nav_group: "work",
      active_key: "work_workspace",
      catalog_components: [
        :workspace_shell,
        :nav_rail,
        :chat,
        :timeline,
        :composer,
        :utility_drawer,
        :status_badge
      ]
    },
    %{
      route_id: :objectives,
      preview_path: "/preview/objectives",
      title: "Objectives",
      nav_group: "work",
      active_key: "work_objectives",
      catalog_components: [:workspace_shell, :nav_rail, :objective_card, :timeline, :status_badge]
    },
    %{
      route_id: :jobs,
      preview_path: "/preview/jobs",
      title: "Jobs",
      nav_group: "operate",
      active_key: "operate_jobs",
      catalog_components: [:workspace_shell, :nav_rail, :job_card, :table, :status_badge]
    },
    %{
      route_id: :models,
      preview_path: "/preview/models",
      title: "Models",
      nav_group: "operate",
      active_key: "operate_models",
      catalog_components: [
        :workspace_shell,
        :nav_rail,
        :models_panel,
        :settings_card,
        :status_badge
      ]
    },
    %{
      route_id: :channels,
      preview_path: "/preview/channels",
      title: "Channels",
      nav_group: "extend",
      active_key: "extend_channels",
      catalog_components: [
        :workspace_shell,
        :nav_rail,
        :channel_card,
        :settings_card,
        :status_badge
      ]
    },
    %{
      route_id: :settings,
      preview_path: "/preview/settings",
      title: "Settings and policy",
      nav_group: "trust",
      active_key: "trust_settings",
      catalog_components: [
        :workspace_shell,
        :nav_rail,
        :settings_panel,
        :surface_policy_panel,
        :intents_panel
      ]
    },
    %{
      route_id: :trust,
      preview_path: "/preview/trust",
      title: "Trust and audit",
      nav_group: "trust",
      active_key: "trust_audit",
      catalog_components: [
        :workspace_shell,
        :nav_rail,
        :trace_viewer,
        :confirmation_card,
        :approval_card,
        :status_badge
      ]
    }
  ]

  @spec routes() :: [map()]
  def routes, do: @routes

  @spec preview_paths() :: [String.t()]
  def preview_paths, do: Enum.map(@routes, & &1.preview_path)

  @spec nav_items() :: [map()]
  def nav_items do
    Enum.map(@routes, fn route ->
      %{
        label: route.title,
        path: route.preview_path,
        active_key: route.active_key,
        nav_group: route.nav_group
      }
    end)
  end

  @spec get!(atom() | String.t()) :: map()
  def get!(route_id) when is_atom(route_id) do
    Enum.find(@routes, &(&1.route_id == route_id)) ||
      raise ArgumentError, "unknown v0.60 preview route #{inspect(route_id)}"
  end

  def get!(route_id) when is_binary(route_id), do: route_id |> String.to_existing_atom() |> get!()

  @spec known_catalog_components?() :: boolean()
  def known_catalog_components? do
    known = MapSet.new(Catalog.known_components())

    @routes
    |> Enum.flat_map(& &1.catalog_components)
    |> Enum.all?(&MapSet.member?(known, &1))
  end
end
