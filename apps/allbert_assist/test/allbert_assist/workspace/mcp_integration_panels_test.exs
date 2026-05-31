defmodule AllbertAssist.Workspace.McpIntegrationPanelsTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.Resources.{Grants, Ref, ResourceURI, Scope}
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace.McpIntegrationPanels

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-mcp-integration-panels-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    {:ok, _state} =
      Agent.start(fn -> %{resources: [], tools: [], text: "", calls: []} end,
        name: __MODULE__.State
      )

    configure_external()
    stub_mcp()

    on_exit(fn ->
      if Process.whereis(__MODULE__.State), do: Agent.stop(__MODULE__.State)
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "unconfigured calendar, mail, and github panels show discovery affordances" do
    calendar = McpIntegrationPanels.surface(:calendar, %{})
    mail = McpIntegrationPanels.surface(:mail, %{})
    github = McpIntegrationPanels.surface(:github, %{})

    assert calendar.id == :core_calendar_panel
    assert mail.id == :core_mail_panel
    assert github.id == :core_github_panel

    calendar_nodes = flatten(calendar.nodes)
    mail_nodes = flatten(mail.nodes)
    github_nodes = flatten(github.nodes)

    assert node_with?(calendar_nodes, :empty_state, title: "Connect Calendar")
    assert node_with?(mail_nodes, :empty_state, title: "Connect Mail")
    assert node_with?(github_nodes, :empty_state, title: "Connect GitHub")

    assert node_with?(calendar_nodes, :action_button,
             action_name: "find_tools",
             integration: "calendar"
           )

    assert node_with?(mail_nodes, :action_button, action_name: "find_tools", integration: "mail")

    assert node_with?(github_nodes, :action_button,
             action_name: "find_tools",
             integration: "github"
           )
  end

  test "calendar panel renders an agenda resource through mcp_read_resource when a grant exists" do
    uri = "calendar://agenda/today"

    configure_server("calendar", ["create_event"])
    set_mcp_shape([resource(uri, "Today's agenda")], [tool("create_event")], "Standup at 10")
    remember_mcp_resource("calendar", uri)

    surface = McpIntegrationPanels.surface(:calendar, refresh_context())
    nodes = flatten(surface.nodes)

    assert node_with?(nodes, :settings_card, title: "Agenda Resource", body: "Standup at 10")

    assert node_with?(nodes, :action_button,
             action_name: "mcp_read_resource",
             server_id: "calendar",
             resource_uri: uri
           )

    assert node_with?(nodes, :mcp_effect_form,
             action_name: "mcp_call_tool",
             server_id: "calendar",
             tool_name: "create_event",
             title: "Create Event"
           )

    assert calls() == [
             "initialize",
             "resources/list",
             "initialize",
             "tools/list",
             "initialize",
             "resources/read"
           ]
  end

  test "tool-only calendar keeps agenda reads per-call confirmed" do
    configure_server("calendar", ["list_events", "create_event"])
    set_mcp_shape([], [tool("list_events"), tool("create_event")], "")

    surface = McpIntegrationPanels.surface(:calendar, refresh_context())
    nodes = flatten(surface.nodes)

    assert node_with?(nodes, :settings_card,
             title: "Confirmed Agenda Read",
             status: "needs_confirmation"
           )

    assert node_with?(nodes, :action_button,
             action_name: "mcp_call_tool",
             server_id: "calendar",
             tool_name: "list_events"
           )

    refute "resources/read" in calls()
  end

  test "mail panel renders inbox resource summaries and a confirmed reply action" do
    uri = "mailbox://inbox/summary"

    configure_server("mail", ["reply_message"])
    set_mcp_shape([resource(uri, "Inbox summary")], [tool("reply_message")], "3 unread messages")
    remember_mcp_resource("mail", uri)

    surface = McpIntegrationPanels.surface(:mail, refresh_context())
    nodes = flatten(surface.nodes)

    assert node_with?(nodes, :settings_card, title: "Inbox Resource", body: "3 unread messages")

    assert node_with?(nodes, :action_button,
             action_name: "mcp_read_resource",
             server_id: "mail",
             resource_uri: uri
           )

    assert node_with?(nodes, :mcp_effect_form,
             action_name: "mcp_call_tool",
             server_id: "mail",
             tool_name: "reply_message",
             title: "Reply"
           )
  end

  test "tool-only mail keeps inbox summaries behind confirmed tool calls" do
    configure_server("mail", ["list_threads", "send_message"])
    set_mcp_shape([], [tool("list_threads"), tool("send_message")], "")

    surface = McpIntegrationPanels.surface(:mail, refresh_context())
    nodes = flatten(surface.nodes)

    assert node_with?(nodes, :settings_card,
             title: "Confirmed Inbox Summary",
             status: "needs_confirmation"
           )

    assert node_with?(nodes, :action_button,
             action_name: "mcp_call_tool",
             server_id: "mail",
             tool_name: "list_threads"
           )
  end

  test "github panel renders resource-backed PR summaries and confirmed comment action" do
    uri = "github://lexlapax/allbert-assist/pulls/open"

    configure_server("github", ["create_issue_comment"])

    set_mcp_shape(
      [resource(uri, "Open pull requests")],
      [tool("create_issue_comment")],
      "2 open pull requests"
    )

    remember_mcp_resource("github", uri)

    surface = McpIntegrationPanels.surface(:github, refresh_context())
    nodes = flatten(surface.nodes)

    assert node_with?(nodes, :settings_card,
             title: "GitHub Resource",
             body: "2 open pull requests"
           )

    assert node_with?(nodes, :action_button,
             action_name: "mcp_read_resource",
             server_id: "github",
             resource_uri: uri
           )

    assert node_with?(nodes, :mcp_effect_form,
             action_name: "mcp_call_tool",
             server_id: "github",
             tool_name: "create_issue_comment",
             title: "Comment"
           )
  end

  test "tool-only github keeps summaries and searches behind confirmed tool calls" do
    configure_server("github", ["list_pull_requests", "create_issue_comment"])
    set_mcp_shape([], [tool("list_pull_requests"), tool("create_issue_comment")], "")

    surface = McpIntegrationPanels.surface(:github, refresh_context())
    nodes = flatten(surface.nodes)

    assert node_with?(nodes, :settings_card,
             title: "Confirmed GitHub Summary",
             status: "needs_confirmation"
           )

    assert node_with?(nodes, :action_button,
             action_name: "mcp_call_tool",
             server_id: "github",
             tool_name: "list_pull_requests"
           )
  end

  defp refresh_context do
    %{
      actor: "local",
      user_id: "local",
      operator_id: "local",
      mcp_panel_refresh?: true,
      mcp: %{req_plug: {Req.Test, __MODULE__}}
    }
  end

  defp configure_server(server_id, tool_allowlist) do
    assert {:ok, _setting} =
             Settings.put("mcp.servers.#{server_id}.enabled", false, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.#{server_id}.transport", "streamable_http", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("mcp.servers.#{server_id}.base_url", "https://example.com/mcp", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("mcp.servers.#{server_id}.tool_allowlist", tool_allowlist, %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("mcp.servers.#{server_id}.confirmation", "required", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.#{server_id}.enabled", true, %{audit?: false})
  end

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/mcp"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_methods", ["POST"], %{audit?: false})
  end

  defp remember_mcp_resource(server_id, uri) do
    resource_uri = ResourceURI.mcp!(server_id, uri)

    ref =
      Ref.new!(%{
        resource_uri: resource_uri,
        origin_kind: :mcp_resource,
        canonical_id: resource_uri,
        operation_class: :mcp_resource_read,
        access_mode: :read,
        scope: Scope.mcp_server(server_id),
        downstream_consumer: "mcp_resource_reader",
        display_uri: uri,
        metadata: %{server_id: server_id, server_resource_uri: uri}
      })

    assert {:ok, _grant} =
             Grants.remember(ref, %{
               action_permission: :mcp_resource_read,
               actor: "local",
               channel: :test,
               audit?: false
             })
  end

  defp set_mcp_shape(resources, tools, text) do
    Agent.update(__MODULE__.State, fn state ->
      %{state | resources: resources, tools: tools, text: text, calls: []}
    end)
  end

  defp stub_mcp do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      method = request["method"]
      Agent.update(__MODULE__.State, &Map.update!(&1, :calls, fn calls -> calls ++ [method] end))

      state = Agent.get(__MODULE__.State, & &1)

      result =
        case method do
          "initialize" ->
            %{"protocolVersion" => "2025-03-26", "capabilities" => %{}}

          "resources/list" ->
            %{"resources" => state.resources}

          "tools/list" ->
            %{"tools" => state.tools}

          "resources/read" ->
            %{
              "contents" => [
                %{
                  "uri" => get_in(request, ["params", "uri"]),
                  "mimeType" => "text/plain",
                  "text" => state.text
                }
              ]
            }
        end

      response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      Plug.Conn.send_resp(conn, 200, response)
    end)
  end

  defp resource(uri, name), do: %{"uri" => uri, "name" => name, "mimeType" => "text/plain"}
  defp tool(name), do: %{"name" => name, "description" => "#{name} tool", "inputSchema" => %{}}

  defp calls, do: Agent.get(__MODULE__.State, & &1.calls)

  defp flatten(nodes), do: Enum.flat_map(nodes, &flatten_node/1)

  defp flatten_node(%{children: children} = node),
    do: [node | Enum.flat_map(children, &flatten_node/1)]

  defp flatten_node(node), do: [node]

  defp node_with?(nodes, component, props) do
    Enum.any?(nodes, fn node ->
      node.component == component and
        Enum.all?(props, fn {key, value} -> Map.get(node.props, key) == value end)
    end)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
