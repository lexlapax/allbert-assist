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
  # the app (release-pinned, not semantic-per-app). v0.61b (0.61.1) consolidates
  # the shell per ADR 0080: the workspace submenu column and per-shell top bars
  # retire (one sidebar with contextual workspace sections), the canvas docks as
  # a resizable pane, and the sidebar collapses to a rail. Convention is
  # documented in DEVELOPMENT.md "App version metadata".
  def version, do: "0.61.1"

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
    ] ++
      core_agent_descriptors() ++
      v056_full_coverage_descriptors() ++ MarketplaceSurfaceProvider.intent_descriptors()
  end

  # v0.54 M9.1: descriptor coverage for agent-exposed core verbs. Core actions carry
  # `app_id: nil`; declared here under the reserved `:allbert` id (ADR 0062 Option 1,
  # accepted in Descriptor.normalize). Routing grants no authority — effectful
  # actions still hit their permission/confirmation gate.
  defp core_agent_descriptors do
    [
      %{
        app_id: :allbert,
        action_name: "append_memory",
        label: "Remember a fact in memory",
        examples: [
          "remember that my anniversary is June 20",
          "note to self: the team retro is every Friday",
          "remember I prefer aisle seats"
        ],
        synonyms: ["remember", "remember that", "note to self", "memorize", "keep in mind"],
        vocabulary: %{
          negative_phrases: [
            "my password",
            "my passphrase",
            "my secret",
            "my token",
            "my api key",
            "private key"
          ],
          allow_single_token_match: false
        },
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "read_recent_memory",
        label: "Recall recent memory",
        examples: [
          "what do you remember about me",
          "what do you remember",
          "recall my recent notes to self"
        ],
        synonyms: ["recall", "what do you remember", "my memory", "recent memory"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "generate_image",
        label: "Generate an image",
        examples: [
          "generate an image of a red bicycle",
          "create a picture of a mountain sunset",
          "make an image of a robot reading a book"
        ],
        synonyms: ["generate image", "create image", "make a picture", "draw", "image of"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "list_settings",
        label: "Show settings",
        examples: ["show my settings", "list settings", "what are my current settings"],
        synonyms: ["settings", "show settings", "list settings", "my settings"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "update_setting",
        label: "Change a setting",
        examples: [
          "change a setting",
          "set the intent router strategy to deterministic",
          "update my setting"
        ],
        synonyms: ["change setting", "update setting", "set setting", "configure"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "set_active_model_profile",
        label: "Switch the active model profile",
        examples: [
          "switch to the fast model",
          "use the local model profile",
          "set the active model to slow"
        ],
        synonyms: ["switch model", "use model", "set model", "change model profile"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "list_model_profiles",
        label: "List model profiles",
        examples: ["what models do I have", "list model profiles", "show available models"],
        synonyms: ["list models", "model profiles", "available models"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "list_objectives",
        label: "List objectives",
        examples: ["what are my open goals", "list my objectives", "show my goals"],
        synonyms: ["my goals", "objectives", "open goals", "list objectives"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "find_mcp_tools",
        label: "Find MCP tools",
        examples: ["what MCP tools do I have", "find mcp tools", "list available mcp tools"],
        synonyms: ["mcp tools", "find tools", "available tools"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "list_channels",
        label: "List channels",
        examples: ["list my channels", "what channels are connected", "show channels"],
        synonyms: ["channels", "my channels", "connected channels"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "resume_thread_on_channel",
        label: "Resume a thread on a channel",
        examples: [
          "resume my telegram thread",
          "continue this conversation on slack",
          "resume thread on discord"
        ],
        synonyms: ["resume thread", "continue on channel", "resume on"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "list_apps",
        label: "List apps",
        examples: ["list my apps", "what apps are installed", "show apps"],
        synonyms: ["apps", "my apps", "installed apps"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "list_plugins",
        label: "List plugins",
        examples: ["list my plugins", "what plugins are installed", "show plugins"],
        synonyms: ["plugins", "my plugins", "installed plugins"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "list_skills",
        label: "List skills",
        examples: ["what skills do I have", "list my skills", "show available skills"],
        synonyms: ["skills", "my skills", "available skills", "list skills"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "run_shell_command",
        label: "Run a shell command",
        examples: [
          "run the command ls -la",
          "run a shell command",
          "execute df -h in the shell"
        ],
        synonyms: ["run command", "shell command", "execute command", "run in shell"],
        required_slots: [],
        handoff_required?: true
      },
      # v0.54 M10 outbound compose (ADR 0063)
      %{
        app_id: :allbert,
        action_name: "send_email",
        label: "Send an email",
        examples: [
          "send an email to alice@example.com about lunch",
          "email bob@example.com saying the report is ready",
          "draft an email to the team about the release"
        ],
        synonyms: ["send email", "email", "compose email", "draft email", "write an email"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "send_channel_message",
        label: "Send a channel message",
        examples: [
          "send a slack message to #eng saying hi",
          "post to the general channel that the deploy is done",
          "message the team channel"
        ],
        synonyms: ["send a message", "post to channel", "message channel", "send to slack"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "create_calendar_event",
        label: "Create a calendar event",
        examples: [
          "schedule a meeting tomorrow at 3pm",
          "create a calendar event for the sync on Friday",
          "add a meeting with Alice next Monday"
        ],
        synonyms: ["schedule a meeting", "create event", "add to calendar", "book a meeting"],
        required_slots: [],
        handoff_required?: true
      },
      # v0.54 M10 effectful-verb promotions (gated)
      %{
        app_id: :allbert,
        action_name: "install_marketplace_bundle",
        label: "Install a marketplace bundle",
        examples: [
          "install the allbert/research-helpers skill",
          "install a bundle from the marketplace",
          "add the research helpers marketplace skill"
        ],
        synonyms: [
          "install marketplace",
          "install bundle",
          "install skill",
          "add marketplace skill"
        ],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "create_skill",
        label: "Create a skill",
        examples: [
          "create a skill that drafts standup notes",
          "make a new skill for summarizing meetings",
          "scaffold a skill called release-notes"
        ],
        synonyms: ["create skill", "make a skill", "new skill", "scaffold skill"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "continue_objective",
        label: "Continue an objective",
        examples: ["continue my goal", "resume the objective", "keep going on my objective"],
        synonyms: ["continue objective", "resume objective", "continue goal"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "cancel_objective",
        label: "Cancel an objective",
        examples: ["cancel my objective", "stop the goal", "abandon this objective"],
        synonyms: ["cancel objective", "stop goal", "abandon objective"],
        required_slots: [],
        handoff_required?: true
      }
    ]
  end

  defp v056_full_coverage_descriptors do
    [
      %{
        app_id: :allbert,
        action_name: "activate_skill",
        label: "Activate a skill",
        examples: ["activate the tdd skill", "enable the grill-me skill", "turn on pdf skill"],
        synonyms: ["activate skill", "enable skill", "turn on skill"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "channel_setup_check",
        label: "Check channel setup",
        examples: [
          "check channel setup",
          "run the channel setup check",
          "verify my channel configuration"
        ],
        synonyms: ["channel setup", "setup check", "channel configuration check"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "direct_answer",
        label: "Answer directly",
        examples: [
          "answer directly: why is the sky blue",
          "just answer this question",
          "give me a direct answer"
        ],
        synonyms: ["direct answer", "answer directly", "just answer"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "doctor_model_profile",
        label: "Doctor a model profile",
        examples: [
          "doctor the local model profile",
          "check the router model profile",
          "diagnose model profile health"
        ],
        synonyms: ["model doctor", "doctor model profile", "model profile health"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "doctor_voice_provider",
        label: "Doctor a voice provider",
        examples: [
          "doctor the voice provider",
          "check voice provider health",
          "diagnose speech provider setup"
        ],
        synonyms: ["voice doctor", "voice provider doctor", "speech provider health"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "explain_setting",
        label: "Explain a setting",
        examples: [
          "explain the operator.timezone setting",
          "why is this setting set",
          "show the layers for operator timezone"
        ],
        synonyms: ["explain setting", "setting layers", "why setting"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "external_network_request",
        label: "Plan an external network request",
        examples: [
          "fetch https://example.com with a GET request",
          "make an external network request",
          "call this HTTP endpoint"
        ],
        synonyms: ["external network request", "http request", "fetch url", "call endpoint"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "get_public_call_result",
        label: "Get a public protocol call result",
        examples: [
          "get public call result abc123",
          "show public call result",
          "fetch the public protocol result"
        ],
        synonyms: ["public call result", "public protocol result", "get call result"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "list_provider_profiles",
        label: "List provider profiles",
        examples: [
          "list provider profiles",
          "show configured providers",
          "what provider profiles do I have"
        ],
        synonyms: ["provider profiles", "configured providers", "list providers"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "plan_package_install",
        label: "Plan a package install",
        examples: [
          "plan installing the jq package",
          "plan a package install",
          "prepare installing ripgrep"
        ],
        synonyms: ["plan package install", "package install plan", "install package plan"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "plan_shell_command",
        label: "Plan a shell command",
        examples: [
          "plan the shell command to list files",
          "plan running ls -la",
          "prepare a shell command"
        ],
        synonyms: ["plan shell command", "shell command plan", "prepare command"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "read_setting",
        label: "Read one setting",
        examples: [
          "read setting operator.timezone",
          "show setting intent.router_strategy",
          "get the operator communication style setting"
        ],
        synonyms: ["read setting", "show setting", "get setting"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "read_skill",
        label: "Read a skill",
        examples: ["read the tdd skill", "open the skill instructions", "show the pdf skill"],
        synonyms: ["read skill", "open skill", "show skill"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "search_online_skills",
        label: "Search online skills",
        examples: [
          "search online skills for pdf extraction",
          "find installable skills for spreadsheets",
          "look up online skills"
        ],
        synonyms: ["search online skills", "find online skills", "installable skills"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "set_provider_credential",
        label: "Set a provider credential",
        examples: [
          "set the openai provider credential",
          "configure the anthropic api key",
          "update provider credential"
        ],
        synonyms: ["set provider credential", "provider api key", "configure provider key"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "show_app",
        label: "Show an app",
        examples: ["show the allbert app", "show app details", "open the telegram app info"],
        synonyms: ["show app", "app details", "app info"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "show_channel",
        label: "Show a channel",
        examples: [
          "show the telegram channel",
          "show channel slack",
          "open channel details"
        ],
        synonyms: ["show channel", "channel details", "channel info"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "show_online_skill",
        label: "Show an online skill",
        examples: [
          "show the online skill pdf extraction",
          "open online skill details",
          "show installable skill details"
        ],
        synonyms: ["show online skill", "online skill details", "installable skill details"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "show_plugin",
        label: "Show a plugin",
        examples: ["show the telegram plugin", "show plugin details", "open plugin info"],
        synonyms: ["show plugin", "plugin details", "plugin info"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "synthesize_voice",
        label: "Synthesize voice",
        examples: [
          "synthesize voice saying hello",
          "speak this text out loud",
          "generate text to speech"
        ],
        synonyms: ["synthesize voice", "text to speech", "speak text", "generate speech"],
        required_slots: [],
        handoff_required?: true
      },
      %{
        app_id: :allbert,
        action_name: "unsupported_resource_workflow",
        label: "Handle an unsupported resource workflow",
        examples: [
          "open resource foo://unsupported",
          "handle this unsupported resource",
          "what can you do with this resource URI"
        ],
        synonyms: ["unsupported resource", "resource workflow", "unknown resource"],
        required_slots: [],
        handoff_required?: true
      }
    ]
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
      panel_surface(:core_intents_panel, "Intents", :canvas_panels, 45, [
        panel_node("core-intents", "Intents", "Coverage, eval status, and descriptor review.", [
          %Node{
            id: "intents-panel",
            component: :intents_panel,
            props: %{zone: "canvas", title: "Intents"}
          }
        ])
      ]),
      panel_surface(:core_models_panel, "Models", :canvas_panels, 46, [
        panel_node("core-models", "Models", "Recommendation matrix and redacted inventories.", [
          %Node{
            id: "models-panel",
            component: :models_panel,
            props: %{zone: "canvas", title: "Models"}
          }
        ])
      ]),
      panel_surface(:core_channels_panel, "Channels", :canvas_panels, 48, [
        panel_node(
          "core-channels",
          "Channels",
          "Connect Allbert to external channels and apps. This is a presentation-only " <>
            "view; configuring a channel routes through Security Central like any other " <>
            "capability.",
          [
            %Node{
              id: "channels-panel",
              component: :channels_panel,
              props: %{zone: "canvas", title: "Channels"}
            }
          ]
        )
      ]),
      panel_surface(
        :core_surface_policy_panel,
        "Surface Policy",
        :canvas_panels,
        47,
        [
          panel_node(
            "core-surface-policy",
            "Surface Policy",
            "Security Central policy posture and M11 editor entry point.",
            [
              %Node{
                id: "surface-policy-panel",
                component: :surface_policy_panel,
                props: %{zone: "canvas", title: "Surface Policy"}
              }
            ]
          )
        ]
      ),
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
          # v0.61b M7 (ADR 0080 §2): the workspace appbar (:header node) is
          # retired — brand lives in the sidebar header, its controls re-home
          # per the M0 relocation table (chat header, pane header, sidebar
          # footer). The :header atom stays registered-but-unused.
          # v0.61b M5 (ADR 0080 §1): the workspace-local submenu column
          # (nav_rail + thread_list + app_launcher nodes) is retired — its
          # sections nest under the product sidebar's Workspace entry. The
          # component atoms stay registered-but-unused in Surface.Catalog
          # (operator decision 2026-07-02).
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
