defmodule AllbertAssist.Workspace.McpIntegrationPanels do
  @moduledoc """
  Host-owned workspace panels for v0.42 MCP-configured integrations.

  The panels use only registered actions for MCP discovery and reads. They never
  invoke `AllbertAssist.Mcp.Client` or a transport directly.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Mcp.ServerConfig
  alias AllbertAssist.Resources.{Grants, Ref, ResourceURI, Scope}
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node

  @spec surfaces(map()) :: [Surface.t()]
  def surfaces(context \\ %{}) when is_map(context) do
    [
      surface(:calendar, context),
      surface(:mail, context)
    ]
  end

  @spec surface(:calendar | :mail, map()) :: Surface.t()
  def surface(integration, context \\ %{}) when integration in [:calendar, :mail] do
    spec = spec(integration)

    %Surface{
      id: spec.surface_id,
      app_id: :allbert,
      label: spec.label,
      path: "/workspace",
      kind: :panel,
      zone: :canvas_panels,
      status: :available,
      nodes: [panel_node(spec, context)],
      fallback_text: "#{spec.label} is available in the workspace.",
      metadata: %{visible_when: :operator_opened, order: spec.order}
    }
  end

  defp panel_node(spec, context) do
    case server_state(spec, context) do
      {:unconfigured, _reason} ->
        unconfigured_panel(spec)

      {:configured_disabled, config} ->
        configured_disabled_panel(spec, config)

      {:configured, config, discovery} ->
        configured_panel(spec, config, discovery, context)
    end
  end

  defp server_state(spec, context) do
    case ServerConfig.resolve(spec.server_id) do
      {:ok, %ServerConfig{enabled?: false} = config} ->
        {:configured_disabled, config}

      {:ok, %ServerConfig{} = config} ->
        {:configured, config, discovery(spec, config, context)}

      {:error, reason} ->
        {:unconfigured, reason}
    end
  end

  defp unconfigured_panel(spec) do
    %Node{
      id: "#{spec.id}-mcp-panel",
      component: :panel,
      props: %{
        title: spec.label,
        body: "No #{spec.server_id} MCP server is configured."
      },
      children: [
        %Node{
          id: "#{spec.id}-mcp-empty",
          component: :empty_state,
          props: %{
            title: "Connect #{spec.label}",
            body: spec.empty_body
          }
        },
        %Node{
          id: "#{spec.id}-mcp-discover",
          component: :action_button,
          props: %{
            title: "Discover Servers",
            phx_click: "discover_mcp_integration",
            action_name: "find_tools",
            integration: Atom.to_string(spec.id)
          }
        },
        %Node{
          id: "#{spec.id}-mcp-discover-link",
          component: :link,
          props: %{
            title: "Open Discovery",
            href: "/workspace?destination=workspace:discover"
          }
        }
      ]
    }
  end

  defp configured_disabled_panel(spec, config) do
    %Node{
      id: "#{spec.id}-mcp-panel",
      component: :panel,
      props: %{
        title: spec.label,
        body: "#{spec.server_id} MCP server is configured but disabled."
      },
      children: [
        server_card(spec, config, "disabled"),
        %Node{
          id: "#{spec.id}-mcp-disabled",
          component: :empty_state,
          props: %{
            title: "#{spec.label} Disabled",
            body:
              "Enable mcp.servers.#{spec.server_id}.enabled after credentials and doctor checks pass."
          }
        }
      ]
    }
  end

  defp configured_panel(spec, config, discovery, context) do
    read_nodes =
      spec
      |> read_nodes(config, discovery, context)
      |> List.wrap()

    effect_nodes =
      spec
      |> effect_nodes(config, discovery)
      |> List.wrap()

    %Node{
      id: "#{spec.id}-mcp-panel",
      component: :panel,
      props: %{
        title: spec.label,
        body: configured_panel_body(spec, discovery)
      },
      children:
        [
          server_card(spec, config, "configured"),
          discovery_status_node(spec, discovery)
        ] ++ read_nodes ++ effect_nodes
    }
  end

  defp configured_panel_body(%{id: :calendar}, %{resource: nil}) do
    "Calendar agenda reads are operator-triggered and confirmed unless a resource-backed agenda is exposed."
  end

  defp configured_panel_body(%{id: :calendar}, _discovery) do
    "Calendar agenda reads use mcp_read_resource when a remembered MCP Resource Access grant exists."
  end

  defp configured_panel_body(%{id: :mail}, %{resource: nil}) do
    "Mail inbox summaries use confirmed MCP tool calls until a mailbox resource is exposed."
  end

  defp configured_panel_body(%{id: :mail}, _discovery) do
    "Mail inbox summaries use mcp_read_resource for resource-backed headers and message previews."
  end

  defp read_nodes(spec, _config, %{resource: resource}, context)
       when is_map(resource) do
    uri = field(resource, "uri")

    case read_resource_preview(spec, uri, context) do
      {:ok, preview} ->
        [
          read_card(spec, resource, preview),
          read_resource_button(spec, uri)
        ]

      :needs_grant ->
        [
          read_card(spec, resource, spec.resource_grant_body),
          read_resource_button(spec, uri)
        ]

      {:error, reason} ->
        [
          read_card(
            spec,
            resource,
            "Resource read failed through mcp_read_resource: #{inspect(reason)}."
          ),
          read_resource_button(spec, uri)
        ]
    end
  end

  defp read_nodes(spec, _config, discovery, _context) do
    case discovery.read_tool do
      %{"name" => tool_name} ->
        [
          %Node{
            id: "#{spec.id}-mcp-tool-read",
            component: :settings_card,
            props: %{
              title: spec.tool_read_card_title,
              body: spec.tool_read_body,
              status: "needs_confirmation",
              external_id: tool_name
            }
          },
          mcp_call_button(spec, spec.tool_read_title, tool_name, "#{spec.id}_read")
        ]

      _tool ->
        [
          %Node{
            id: "#{spec.id}-mcp-no-read",
            component: :empty_state,
            props: %{
              title: spec.no_read_title,
              body: spec.no_read_body
            }
          }
        ]
    end
  end

  defp effect_nodes(spec, _config, discovery) do
    case discovery.effect_tool do
      %{"name" => tool_name} ->
        [
          mcp_call_button(spec, spec.effect_title, tool_name, "#{spec.id}_effect")
        ]

      _tool ->
        [
          %Node{
            id: "#{spec.id}-mcp-no-effect",
            component: :settings_card,
            props: %{
              title: spec.no_effect_title,
              body: spec.no_effect_body,
              status: "blocked"
            }
          }
        ]
    end
  end

  defp server_card(spec, config, status) do
    summary = ServerConfig.summary(config)

    %Node{
      id: "#{spec.id}-mcp-server",
      component: :settings_card,
      props: %{
        title: "Server #{spec.server_id}",
        body:
          "#{summary.transport} at #{summary.redacted_host}; confirmation #{summary.confirmation}.",
        status: status,
        external_id: spec.server_id
      }
    }
  end

  defp discovery_status_node(spec, discovery) do
    %Node{
      id: "#{spec.id}-mcp-discovery-status",
      component: :status_badge,
      props: %{
        title: "MCP discovery",
        body: discovery_status_text(discovery),
        status: discovery_status(discovery)
      }
    }
  end

  defp discovery_status_text(%{resource_count: resource_count, tool_count: tool_count}) do
    "#{resource_count} resource(s), #{tool_count} tool(s)"
  end

  defp discovery_status(_discovery), do: "info"

  defp read_card(spec, resource, body) do
    %Node{
      id: "#{spec.id}-mcp-resource",
      component: :settings_card,
      props: %{
        title: spec.resource_card_title,
        body: body,
        status: "completed",
        external_id: field(resource, "uri")
      }
    }
  end

  defp read_resource_button(spec, uri) do
    %Node{
      id: "#{spec.id}-mcp-read-resource",
      component: :action_button,
      props: %{
        title: spec.resource_read_title,
        phx_click: "run_mcp_integration_action",
        action_name: "mcp_read_resource",
        integration: Atom.to_string(spec.id),
        server_id: spec.server_id,
        resource_uri: uri
      }
    }
  end

  defp mcp_call_button(spec, title, tool_name, operation) do
    %Node{
      id: "#{spec.id}-mcp-#{operation}",
      component: :action_button,
      props: %{
        title: title,
        phx_click: "run_mcp_integration_action",
        action_name: "mcp_call_tool",
        integration: Atom.to_string(spec.id),
        integration_action: operation,
        server_id: spec.server_id,
        tool_name: tool_name
      }
    }
  end

  defp discovery(spec, config, context) do
    if refresh?(spec, context) do
      action_context = action_context(context, spec)
      resources = action_items("mcp_list_resources", :resources, spec.server_id, action_context)
      tools = action_items("mcp_list_tools", :tools, spec.server_id, action_context)

      tools = tools ++ fallback_tools(config, tools)
      resource = select_item(resources, spec.resource_keywords)
      read_tool = select_named_tool(tools, spec.read_tools)
      effect_tool = select_named_tool(tools, spec.effect_tools)

      %{
        resources: resources,
        tools: tools,
        resource: resource,
        read_tool: read_tool,
        effect_tool: effect_tool,
        resource_count: length(resources),
        tool_count: length(tools)
      }
    else
      tools = fallback_tools(config, [])

      %{
        resources: [],
        tools: tools,
        resource: nil,
        read_tool: select_named_tool(tools, spec.read_tools),
        effect_tool: select_named_tool(tools, spec.effect_tools),
        resource_count: 0,
        tool_count: length(tools)
      }
    end
  end

  defp refresh?(spec, context) do
    Map.get(context, :mcp_panel_refresh?) == true ||
      Map.get(context, "mcp_panel_refresh?") == true ||
      Map.get(context, :canvas_destination) == "workspace:#{spec.id}" ||
      Map.get(context, "canvas_destination") == "workspace:#{spec.id}"
  end

  defp action_items(action_name, key, server_id, context) do
    case Runner.run(action_name, %{server_id: server_id, limit: 16}, context) do
      {:ok, %{status: :completed} = response} ->
        response
        |> Map.get(key, [])
        |> Enum.filter(&is_map/1)

      _other ->
        []
    end
  rescue
    _error in [DBConnection.OwnershipError, DBConnection.ConnectionError] -> []
  end

  defp fallback_tools(%ServerConfig{tool_allowlist: names}, listed_tools) when is_list(names) do
    listed_names =
      listed_tools
      |> Enum.map(&field(&1, "name"))
      |> MapSet.new()

    names
    |> Enum.reject(&MapSet.member?(listed_names, &1))
    |> Enum.map(&%{"name" => &1, "description" => "Configured allowlist tool."})
  end

  defp select_item(items, keywords) do
    Enum.find(items, &matches_any?(&1, keywords)) || List.first(items)
  end

  defp select_named_tool(tools, names) do
    names = MapSet.new(names)

    Enum.find(tools, fn tool ->
      tool
      |> field("name")
      |> then(&MapSet.member?(names, &1))
    end)
  end

  defp matches_any?(item, keywords) do
    text =
      item
      |> Map.take(["uri", "name", "description", "mimeType"])
      |> Map.values()
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &to_string/1)
      |> String.downcase()

    Enum.any?(keywords, &String.contains?(text, &1))
  end

  defp read_resource_preview(_spec, nil, _context), do: :needs_grant

  defp read_resource_preview(spec, uri, context) do
    action_context = action_context(context, spec)

    with {:ok, ref} <- read_ref(spec.server_id, uri),
         {:ok, _grant} <-
           Grants.find_applicable(ref, permission: :mcp_resource_read, context: action_context),
         {:ok, %{status: :completed, resource: resource}} <-
           Runner.run(
             "mcp_read_resource",
             %{server_id: spec.server_id, uri: uri, downstream_consumer: "mcp_resource_reader"},
             action_context
           ) do
      {:ok, preview(resource)}
    else
      {:error, :no_matching_grant} -> :needs_grant
      {:error, {:policy_denied, _decision}} -> :needs_grant
      {:ok, %{status: :needs_confirmation}} -> :needs_grant
      {:ok, response} -> {:error, Map.get(response, :error, Map.get(response, :status))}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in [DBConnection.OwnershipError, DBConnection.ConnectionError] -> :needs_grant
  end

  defp read_ref(server_id, uri) do
    with {:ok, resource_uri} <- ResourceURI.mcp(server_id, uri),
         {:ok, derived} <- ResourceURI.derived_fields(resource_uri) do
      Ref.new(%{
        resource_uri: resource_uri,
        origin_kind: :mcp_resource,
        canonical_id: resource_uri,
        operation_class: :mcp_resource_read,
        access_mode: :read,
        scope: Scope.mcp_server(server_id),
        downstream_consumer: "mcp_resource_reader",
        display_uri: uri,
        metadata: %{
          server_id: server_id,
          server_resource_uri: derived.server_resource_uri
        }
      })
    end
  end

  defp preview(%{contents: contents}) when is_list(contents) do
    contents
    |> Enum.find_value(fn content ->
      field(content, "text_preview") || field(content, "blob_bytes")
    end)
    |> case do
      nil -> "MCP resource read completed."
      value -> to_string(value)
    end
  end

  defp preview(_resource), do: "MCP resource read completed."

  defp action_context(context, spec) do
    context
    |> Map.take([
      :actor,
      :user_id,
      :operator_id,
      :thread_id,
      :session_id,
      :mcp,
      "mcp",
      :external,
      "external"
    ])
    |> Map.put_new(:actor, Map.get(context, :user_id, "local"))
    |> Map.put_new(:user_id, Map.get(context, :user_id, "local"))
    |> Map.put_new(
      :operator_id,
      Map.get(context, :operator_id, Map.get(context, :user_id, "local"))
    )
    |> Map.put_new(:channel, :workspace)
    |> Map.put(:surface, "workspace:#{spec.id}")
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key, Map.get(map, existing_atom(key), default))
  end

  defp field(_map, _key, default), do: default

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp spec(:calendar) do
    %{
      id: :calendar,
      server_id: "calendar",
      surface_id: :core_calendar_panel,
      label: "Calendar",
      order: 60,
      empty_body:
        "Discover a calendar MCP server, connect it through consent, then enable it after credentials and doctor checks pass.",
      resource_keywords: ["agenda", "calendar", "event"],
      resource_card_title: "Agenda Resource",
      resource_read_title: "Read Agenda Resource",
      resource_grant_body:
        "Agenda refresh requires an MCP Resource Access grant; approve once with an MCP-server remember scope for prompt-free refresh.",
      read_tools: ["list_events", "list_calendars", "get_event", "show_agenda", "today_agenda"],
      tool_read_title: "Request Agenda Tool Read",
      tool_read_card_title: "Confirmed Agenda Read",
      tool_read_body:
        "This calendar server exposes agenda data through tools, so reads stay per-call confirmed.",
      effect_tools: ["create_event", "update_event"],
      effect_title: "Create Event",
      no_read_title: "No Agenda Read",
      no_read_body:
        "Configure a resource-exposing calendar server or allowlist a read tool such as list_events.",
      no_effect_title: "No Event Write Tool",
      no_effect_body: "No create/update calendar tool is exposed or allowlisted."
    }
  end

  defp spec(:mail) do
    %{
      id: :mail,
      server_id: "mail",
      surface_id: :core_mail_panel,
      label: "Mail",
      order: 65,
      empty_body:
        "Discover a mail MCP server, connect it through consent, then enable it after credentials and doctor checks pass.",
      resource_keywords: ["inbox", "mailbox", "message", "thread", "mail"],
      resource_card_title: "Inbox Resource",
      resource_read_title: "Read Inbox Resource",
      resource_grant_body:
        "Inbox summaries require an MCP Resource Access grant; approve once with an MCP-server remember scope for prompt-free header refresh.",
      read_tools: [
        "list_threads",
        "read_message",
        "search_messages",
        "list_inbox",
        "summarize_inbox"
      ],
      tool_read_title: "Request Inbox Tool Summary",
      tool_read_card_title: "Confirmed Inbox Summary",
      tool_read_body:
        "This mail server exposes summary data through tools, so reads stay per-call confirmed.",
      effect_tools: ["reply_message", "send_message", "modify_labels"],
      effect_title: "Reply",
      no_read_title: "No Inbox Read",
      no_read_body:
        "Configure a resource-exposing mail server or allowlist a read tool such as list_threads.",
      no_effect_title: "No Mail Write Tool",
      no_effect_body: "No reply/send/modify mail tool is exposed or allowlisted."
    }
  end
end
