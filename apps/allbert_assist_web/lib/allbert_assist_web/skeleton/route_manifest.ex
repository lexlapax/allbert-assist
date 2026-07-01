defmodule AllbertAssistWeb.Skeleton.RouteManifest do
  @moduledoc """
  v0.60 preview route manifest copied from `docs/design/information-architecture.md`.

  The walking-skeleton test compares this module row-for-row with the docs table
  before route smoke can pass.
  """

  alias AllbertAssist.Surface.Catalog

  @type route_id ::
          :launch
          | :onboarding
          | :workspace
          | :objectives
          | :jobs
          | :models
          | :channels
          | :settings
          | :trust

  @type catalog_component ::
          :approval_card
          | :button
          | :channel_card
          | :chat
          | :composer
          | :confirmation_card
          | :empty_state
          | :intents_panel
          | :job_card
          | :models_panel
          | :nav_rail
          | :objective_card
          | :onboarding_panel
          | :settings_card
          | :settings_panel
          | :status_badge
          | :surface_policy_panel
          | :table
          | :timeline
          | :trace_viewer
          | :utility_drawer
          | :workspace_shell

  @type route :: %{
          required(:route_id) => route_id(),
          required(:preview_path) => String.t(),
          required(:title) => String.t(),
          required(:nav_group) => String.t(),
          required(:active_key) => String.t(),
          required(:catalog_components) => [catalog_component(), ...]
        }

  @type composition_child :: %{
          required(:component) => catalog_component(),
          required(:node_id) => String.t(),
          required(:placeholder?) => boolean()
        }

  @type composition :: %{
          required(:component) => catalog_component(),
          required(:children) => [composition_child(), ...]
        }

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

  @composition_by_route_id %{
    launch: %{
      component: :button,
      children: [
        %{component: :button, node_id: "v060-launch-button", placeholder?: false}
      ]
    },
    onboarding: %{
      component: :onboarding_panel,
      children: [
        %{
          component: :onboarding_panel,
          node_id: "v060-onboarding-onboarding_panel",
          placeholder?: true
        },
        %{component: :models_panel, node_id: "v060-onboarding-models_panel", placeholder?: true},
        %{component: :status_badge, node_id: "v060-onboarding-review-status", placeholder?: false}
      ]
    },
    workspace: %{
      component: :chat,
      children: [
        %{component: :chat, node_id: "v060-workspace-chat", placeholder?: true},
        %{component: :timeline, node_id: "v060-workspace-timeline", placeholder?: false},
        %{component: :composer, node_id: "v060-workspace-composer", placeholder?: false},
        %{
          component: :utility_drawer,
          node_id: "v060-workspace-utility_drawer",
          placeholder?: false
        }
      ]
    },
    objectives: %{
      component: :objective_card,
      children: [
        %{
          component: :objective_card,
          node_id: "v060-objectives-objective_card",
          placeholder?: false
        },
        %{component: :timeline, node_id: "v060-objectives-timeline", placeholder?: false}
      ]
    },
    jobs: %{
      component: :job_card,
      children: [
        %{component: :job_card, node_id: "v060-jobs-job_card", placeholder?: false},
        %{component: :table, node_id: "v060-jobs-table", placeholder?: false}
      ]
    },
    models: %{
      component: :models_panel,
      children: [
        %{component: :models_panel, node_id: "v060-models-models_panel", placeholder?: true},
        %{component: :settings_card, node_id: "v060-models-settings_card", placeholder?: false}
      ]
    },
    channels: %{
      component: :channel_card,
      children: [
        %{component: :channel_card, node_id: "v060-channels-channel_card", placeholder?: false},
        %{component: :settings_card, node_id: "v060-channels-settings_card", placeholder?: false}
      ]
    },
    settings: %{
      component: :settings_panel,
      children: [
        %{
          component: :settings_panel,
          node_id: "v060-settings-settings_panel",
          placeholder?: true
        },
        %{
          component: :surface_policy_panel,
          node_id: "v060-settings-surface_policy_panel",
          placeholder?: true
        },
        %{component: :intents_panel, node_id: "v060-settings-intents_panel", placeholder?: true}
      ]
    },
    trust: %{
      component: :trace_viewer,
      children: [
        %{component: :trace_viewer, node_id: "v060-trust-trace_viewer", placeholder?: false},
        %{
          component: :confirmation_card,
          node_id: "v060-trust-confirmation_card",
          placeholder?: false
        },
        %{component: :approval_card, node_id: "v060-trust-approval_card", placeholder?: false}
      ]
    }
  }

  @spec routes() :: [route(), ...]
  def routes, do: @routes

  @spec manifest_catalog_components() :: [catalog_component(), ...]
  def manifest_catalog_components do
    @routes
    |> Enum.flat_map(& &1.catalog_components)
    |> Enum.uniq()
  end

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

  @spec composition_for!(route() | route_id()) :: composition()
  def composition_for!(%{route_id: route_id}), do: composition_for!(route_id)

  def composition_for!(route_id) when is_atom(route_id) do
    Map.fetch!(@composition_by_route_id, route_id)
  end

  @spec composition_child_route_count() :: 9
  def composition_child_route_count do
    map_size(@composition_by_route_id)
  end

  @spec known_catalog_components?() :: boolean()
  def known_catalog_components? do
    known = MapSet.new(Catalog.known_components())

    @routes
    |> Enum.flat_map(& &1.catalog_components)
    |> Enum.all?(&MapSet.member?(known, &1))
  end
end
