defmodule AllbertAssist.App.CoreApp do
  @moduledoc false

  use AllbertAssist.App
  use AllbertAssist.App.SurfaceProvider

  alias AllbertAssist.Actions.Integrations.{OpenCalendarPanel, OpenGithubPanel, OpenMailPanel}
  alias AllbertAssist.Marketplace.SurfaceProvider, as: MarketplaceSurfaceProvider
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.{DiscoverySuggestions, McpIntegrationPanels}
  alias AllbertAssist.Workspace.PlanBuild.SurfaceProvider, as: PlanBuildSurfaceProvider

  @impl true
  def app_id, do: :allbert

  @impl true
  def display_name, do: "Allbert"

  @impl true
  # App version follows the Allbert release that last meaningfully changed
  # the app (release-pinned, not semantic-per-app). v0.53.0 adds the
  # channel-pack custody, trust-class, webhook, and mobile-channel surfaces.
  # Convention is documented in DEVELOPMENT.md "App version metadata".
  def version, do: "0.53.0"

  @impl true
  def validate(_opts), do: :ok

  @impl AllbertAssist.App
  def actions do
    [
      OpenCalendarPanel,
      OpenMailPanel,
      OpenGithubPanel
    ]
  end

  @impl AllbertAssist.App
  def signals do
    %{
      emits: [
        "allbert.runtime.turn.started",
        "allbert.runtime.turn.completed"
      ],
      subscribes: []
    }
  end

  @impl AllbertAssist.App
  def surfaces do
    [workspace_surface() | core_panel_surfaces()]
  end

  def workspace_panel_surfaces(context) when is_map(context) do
    core_panel_surfaces(context)
  end

  def surface_catalog do
    Enum.map(Surface.known_components(), fn component ->
      %{component: component, allowed_props: [], allowed_bindings: []}
    end)
  end

  def intent_descriptors do
    [
      %{
        app_id: :allbert,
        action_name: "open_calendar_panel",
        label: "Open Calendar agenda",
        destination: "workspace:calendar",
        examples: [
          "show me today's agenda",
          "show agenda",
          "open calendar"
        ],
        synonyms: ["agenda", "calendar", "today's agenda", "calendar panel"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "open_mail_panel",
        label: "Open Mail inbox",
        destination: "workspace:mail",
        examples: [
          "summarize my inbox",
          "show my inbox",
          "open mail"
        ],
        synonyms: ["inbox", "mail", "email summary", "mail panel"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "open_github_panel",
        label: "Open GitHub work",
        destination: "workspace:github",
        examples: [
          "list my open PRs",
          "show my pull requests",
          "open GitHub"
        ],
        synonyms: ["open prs", "pull requests", "github", "github panel"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "preview_plan",
        label: "Preview a Plan/Build workflow",
        destination: "workspace:plan_build",
        examples: [
          "plan: summarize my inbox and draft a reply",
          "plan list my GitHub issues and email me a summary",
          "preview a plan"
        ],
        synonyms: ["plan", "plan build", "workflow preview", "preview plan"],
        required_slots: [],
        handoff_required?: false
      }
    ] ++ MarketplaceSurfaceProvider.intent_descriptors()
  end

  def fallback_surface(:workspace), do: {:ok, "Allbert workspace is available at /workspace."}

  def fallback_surface(_surface_id), do: {:error, :not_found}

  defp workspace_surface do
    %Surface{
      id: :workspace,
      app_id: :allbert,
      label: "Allbert Workspace",
      path: "/workspace",
      kind: :workspace,
      status: :available,
      nodes: workspace_nodes(),
      fallback_text: "Allbert workspace is available at /workspace."
    }
  end

  defp core_panel_surfaces(context \\ %{}) do
    [
      panel_surface(:core_onboarding_panel, "Onboarding", :canvas_panels, 0, [
        panel_node("core-onboarding", "Onboarding", "First-run setup objective.", [
          %Node{
            id: "onboarding",
            component: :onboarding_panel,
            props: %{zone: "canvas", title: "Onboarding"}
          }
        ])
      ]),
      panel_surface(:core_create_panel, "Create", :canvas_panels, 5, [
        panel_node("core-create", "Create", "Template gallery and preview.", [
          %Node{
            id: "template-create",
            component: :template_create_panel,
            props: %{zone: "canvas", title: "Create"}
          }
        ])
      ]),
      panel_surface(:core_objectives_panel, "Objectives", :canvas_panels, 10, [
        panel_node("core-objectives", "Objectives", "Active work and next steps.", [
          %Node{
            id: "objective-card",
            component: :objective_card,
            props: %{title: "Objectives", body: "Active objectives and blockers.", status: "open"}
          }
        ])
      ]),
      panel_surface(:core_jobs_panel, "Jobs", :canvas_panels, 20, [
        panel_node("core-jobs", "Jobs", "Scheduled and manual runtime work.", [
          %Node{
            id: "job-card",
            component: :job_card,
            props: %{title: "Jobs", body: "Scheduled jobs and run history."}
          },
          %Node{
            id: "jobs-link",
            component: :link,
            props: %{title: "Open jobs", href: "/jobs"}
          }
        ])
      ]),
      panel_surface(:core_confirmations_panel, "Confirmations", :canvas_panels, 30, [
        panel_node("core-confirmations", "Confirmations", "Pending operator decisions.", [
          %Node{
            id: "confirmation-card",
            component: :confirmation_card,
            props: %{
              title: "Confirmations",
              body: "Review pending confirmations in Settings Central.",
              status: "needs_confirmation"
            }
          }
        ])
      ]),
      panel_surface(:core_security_panel, "Security", :canvas_panels, 40, [
        panel_node("core-security", "Security", "Settings, grants, and policy status.", [
          %Node{
            id: "security-card",
            component: :settings_card,
            props: %{title: "Security", body: "Review permission policy and remembered grants."}
          }
        ])
      ]),
      panel_surface(:core_settings_panel, "Settings Central", :canvas_panels, 50, [
        panel_node("core-settings", "Settings Central", "Workspace settings and credentials.", [
          %Node{
            id: "settings-central",
            component: :settings_panel,
            props: %{zone: "canvas", title: "Settings Central"}
          }
        ])
      ]),
      PlanBuildSurfaceProvider.preview_surface(),
      PlanBuildSurfaceProvider.run_progress_surface(),
      MarketplaceSurfaceProvider.catalog_surface(context),
      DiscoverySuggestions.surface(context)
    ] ++
      McpIntegrationPanels.surfaces(context)
  end

  defp panel_surface(id, label, zone, order, nodes) do
    %Surface{
      id: id,
      app_id: :allbert,
      label: label,
      path: "/workspace",
      kind: :panel,
      zone: zone,
      status: :available,
      nodes: nodes,
      fallback_text: "#{label} is available in the workspace.",
      metadata: %{visible_when: :always, order: order}
    }
  end

  defp panel_node(id, title, body, children) do
    %Node{
      id: id,
      component: :panel,
      props: %{title: title, body: body},
      children: children
    }
  end

  defp workspace_nodes do
    [
      %Node{
        id: "workspace-root",
        component: :workspace_shell,
        props: %{layout: "workspace_shell"},
        children: [
          %Node{
            id: "workspace-header",
            component: :header,
            props: %{
              title: "Allbert Workspace",
              subtitle: "Runtime chat, canvas, and ephemeral surfaces."
            }
          },
          %Node{
            id: "workspace-nav-rail",
            component: :nav_rail,
            props: %{zone: "nav_apps"},
            children: [
              %Node{
                id: "workspace-thread-list",
                component: :thread_list,
                props: %{title: "Threads"}
              },
              %Node{
                id: "workspace-app-launcher",
                component: :app_launcher,
                props: %{title: "Apps"}
              }
            ]
          },
          %Node{
            id: "workspace-chat",
            component: :chat,
            props: %{region: "fallback_chat"},
            children: [
              %Node{id: "workspace-chat-timeline", component: :timeline},
              %Node{id: "workspace-chat-composer", component: :composer}
            ]
          },
          %Node{
            id: "workspace-canvas-region",
            component: :canvas,
            props: %{empty?: true, region: "canvas"},
            children: [
              %Node{
                id: "workspace-empty-canvas",
                component: :empty_state,
                props: %{
                  title: "No canvas tiles yet",
                  body: "Workspace tiles will appear here as runtime fragments land."
                }
              }
            ]
          },
          %Node{
            id: "workspace-ephemeral-region",
            component: :ephemeral_surface,
            props: %{empty?: true, region: "ephemeral"}
          }
        ]
      }
    ]
  end
end
