defmodule AllbertAssistWeb.WorkspaceLive do
  @moduledoc """
  Workspace LiveView for talking to the Allbert runtime boundary.

  Routes user prompts through `AllbertAssist.Runtime` asynchronously via
  `start_async/3` so the UI stays responsive.
  """
  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.CoreApp
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations

  alias AllbertAssist.Confirmations.{
    ExternalRequestMetadata,
    OnlineSkillMetadata,
    PackageInstallMetadata,
    ShellCommandMetadata,
    SkillScriptMetadata
  }

  alias AllbertAssist.Conversations
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Runtime
  alias AllbertAssist.Session
  alias AllbertAssist.Settings
  alias AllbertAssist.Theme.Layout
  alias AllbertAssist.Workspace
  alias AllbertAssist.Workspace.Catalog, as: WorkspaceCatalog
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssistWeb.SignalBridge
  alias AllbertAssistWeb.Workspace.Components.TileInspector
  alias AllbertAssistWeb.Workspace.Renderer, as: WorkspaceRenderer
  alias Jido.Signal

  @default_user_id "local"
  @default_session_id "web-local"
  @default_prompt_placeholder "Ask Allbert anything…"
  @workspace_tools ~w(onboard create discover jobs objectives confirmations security settings)

  @impl true
  def mount(params, _session, socket) do
    user_id = @default_user_id
    session_id = @default_session_id
    {thread_id, thread_notice, sync_thread_url?} = resolve_workspace_thread(params, user_id)
    active_app = resolve_workspace_active_app(user_id, session_id)
    canvas_destination = resolve_canvas_destination(params)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(AllbertAssistWeb.PubSub, SignalBridge.topic_for(user_id))

      Phoenix.PubSub.subscribe(
        AllbertAssistWeb.PubSub,
        SignalBridge.workspace_topic_for(user_id, thread_id)
      )

      Process.send_after(self(), :refresh_objectives, 5_000)
    end

    socket =
      socket
      |> assign(
        user_id: user_id,
        thread_id: thread_id,
        session_id: session_id,
        active_app: active_app,
        canvas_destination: canvas_destination,
        workspace_theme: workspace_theme(),
        workspace_high_contrast?: workspace_high_contrast?(),
        workspace_reduce_motion?: workspace_reduce_motion?(),
        workspace_mobile_tab: "chat",
        workspace_offline_enabled?: workspace_offline_enabled?(),
        workspace_indexeddb_quota_bytes: workspace_indexeddb_quota_bytes(),
        workspace_canvas_max_tiles_per_thread: workspace_canvas_max_tiles_per_thread(),
        active_objectives: active_objectives(user_id),
        prompt: "",
        prompt_placeholder: @default_prompt_placeholder,
        response: nil,
        error: nil,
        thread_notice: thread_notice,
        asking?: false,
        status: nil,
        signal_id: nil,
        trace_id: nil,
        approval_handoff: nil,
        approval_lines: [],
        approval_result: nil,
        show_approval_details?: false,
        open_tile_menu_id: nil,
        open_tile_inspector_id: nil,
        thread_switcher_open?: false,
        workspace_launcher_open?: false,
        workspace_badges: [],
        composer_max_bytes: workspace_canvas_tile_body_max_bytes(),
        workspace_overflow_open?: false,
        workspace_maximized_pane: nil,
        canvas_focus?: false
      )
      |> assign(workspace_assigns(user_id, thread_id, [], active_app, canvas_destination))
      |> maybe_sync_thread_url(sync_thread_url?, thread_id, canvas_destination)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{} = params, _uri, socket) do
    socket =
      socket
      |> assign_canvas_destination(resolve_canvas_destination(params))
      |> assign(:workspace_overflow_open?, false)
      |> maybe_assign_mobile_tab(param(params, "tab"))

    {:noreply, socket}
  end

  @impl true
  def handle_event("ask", %{"prompt" => prompt}, socket) do
    {:noreply, submit_workspace_prompt(socket, prompt)}
  end

  def handle_event("ask", _params, socket), do: {:noreply, socket}

  def handle_event("accept_intent_handoff", params, socket) do
    with {:ok, app_id} <- required_param(params, "app-id"),
         {:ok, source_text} <- required_param(params, "source-text"),
         {:ok, %{status: :completed, session: %{active_app: active_app}}} <-
           run_workspace_action(socket, "set_active_app", %{
             user_id: socket.assigns.user_id,
             session_id: socket.assigns.session_id,
             app_id: app_id
           }) do
      socket =
        socket
        |> assign(active_app: active_app, workspace_mobile_tab: "chat", error: nil)
        |> dismiss_intent_surface(params, "handoff_accepted")
        |> refresh_workspace()
        |> push_patch(
          to: workspace_path(socket.assigns.thread_id, socket.assigns.canvas_destination)
        )
        |> submit_workspace_prompt(source_text)

      {:noreply, socket}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :error, "Could not accept app handoff: #{inspect(reason)}")}

      {:ok, response} ->
        {:noreply, assign(socket, :error, Map.get(response, :message, inspect(response)))}
    end
  end

  def handle_event("decline_intent_handoff", params, socket) do
    {:noreply,
     socket
     |> dismiss_intent_surface(params, "handoff_declined")
     |> refresh_workspace()}
  end

  def handle_event("select_intent_option", params, socket) do
    handle_event("accept_intent_handoff", params, socket)
  end

  def handle_event("toggle_approval_details", _params, socket) do
    {:noreply, update(socket, :show_approval_details?, &(!&1))}
  end

  # v0.26a M29: keep `assigns.prompt` in sync as the operator types so the
  # composer reset on submit (and the live character counter) work without
  # re-rendering the entire timeline. The text is bounded server-side by the
  # textarea's `maxlength` attribute (mirrored from
  # `workspace.canvas.tile_body_max_bytes`).
  def handle_event("composer_change", %{"prompt" => prompt}, socket) when is_binary(prompt) do
    {:noreply, assign(socket, :prompt, prompt)}
  end

  def handle_event("composer_change", _params, socket), do: {:noreply, socket}

  # v0.26a M34: AppBar overflow menu open/close. Same shape as the tile
  # kebab — purely UI state, no authority change.
  def handle_event("toggle_workspace_overflow_menu", _params, socket) do
    {:noreply,
     socket
     |> assign(:thread_switcher_open?, false)
     |> update(:workspace_overflow_open?, &(!&1))}
  end

  def handle_event("toggle_thread_switcher", _params, socket) do
    {:noreply,
     socket
     |> assign(:workspace_overflow_open?, false)
     |> update(:thread_switcher_open?, &(!&1))}
  end

  def handle_event("close_thread_switcher", _params, socket) do
    {:noreply, assign(socket, :thread_switcher_open?, false)}
  end

  def handle_event("toggle_workspace_launcher", _params, socket) do
    {:noreply, update(socket, :workspace_launcher_open?, &(!&1))}
  end

  def handle_event("close_workspace_launcher", _params, socket) do
    {:noreply, assign(socket, :workspace_launcher_open?, false)}
  end

  def handle_event("switch_workspace_thread", %{"thread-id" => thread_id}, socket)
      when is_binary(thread_id) and thread_id != "" do
    {:noreply,
     socket
     |> assign(:thread_switcher_open?, false)
     |> assign(:workspace_launcher_open?, false)
     |> push_navigate(to: workspace_path(thread_id, socket.assigns.canvas_destination))}
  end

  def handle_event("switch_workspace_thread", _params, socket), do: {:noreply, socket}

  def handle_event("new_thread", _params, socket) do
    case Conversations.resolve_thread(%{
           user_id: socket.assigns.user_id,
           text: "Workspace session",
           new_thread: true
         }) do
      {:ok, thread} ->
        {:noreply,
         socket
         |> assign(:thread_switcher_open?, false)
         |> assign(:workspace_launcher_open?, false)
         |> push_navigate(to: workspace_path(thread.id, socket.assigns.canvas_destination))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Could not start a new thread: #{inspect(reason)}")}
    end
  end

  # v0.26a M30 follow-up: maximize / restore a workspace pane. Clicking the
  # maximize control on a pane gives it the full grid width and hides the
  # sibling pane; clicking again (or the other pane's control) restores the
  # split. Purely UI state — no authority change.
  def handle_event("toggle_workspace_maximize", %{"pane" => pane}, socket)
      when pane in ["chat", "canvas"] do
    next =
      if socket.assigns.workspace_maximized_pane == pane do
        nil
      else
        pane
      end

    {:noreply, assign(socket, :workspace_maximized_pane, next)}
  end

  def handle_event("toggle_workspace_maximize", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_canvas_focus", _params, socket) do
    {:noreply, update(socket, :canvas_focus?, &(!&1))}
  end

  def handle_event("toggle_workspace_theme", _params, socket) do
    next_theme = next_workspace_theme(socket.assigns.workspace_theme)

    case run_workspace_action(socket, "set_workspace_theme", %{theme: next_theme}) do
      {:ok, %{status: :completed, theme: theme}} ->
        {:noreply, assign(socket, :workspace_theme, theme)}

      {:ok, response} ->
        {:noreply, assign(socket, :error, Map.get(response, :message, inspect(response)))}
    end
  end

  def handle_event("select_workspace_mobile_tab", %{"tab" => tab}, socket)
      when tab in ["chat", "canvas"] do
    {:noreply, assign(socket, :workspace_mobile_tab, tab)}
  end

  def handle_event("select_workspace_mobile_tab", _params, socket), do: {:noreply, socket}

  def handle_event("select_destination", %{"destination" => destination}, socket)
      when is_binary(destination) do
    destination = normalize_canvas_destination(destination)

    {:noreply,
     socket
     |> assign(canvas_destination: destination, workspace_mobile_tab: "canvas")
     |> assign(:workspace_launcher_open?, false)
     |> refresh_workspace()
     |> push_patch(to: workspace_path(socket.assigns.thread_id, destination))}
  end

  def handle_event("select_destination", _params, socket), do: {:noreply, socket}

  def handle_event("select_workspace_app", %{"app-id" => app_id}, socket)
      when is_binary(app_id) and app_id != "" do
    handle_event("select_destination", %{"destination" => "app:#{app_id}"}, socket)
  end

  def handle_event("select_workspace_app", _params, socket), do: {:noreply, socket}

  def handle_event("exit_app_context", _params, socket) do
    case run_workspace_action(socket, "clear_active_app", %{
           user_id: socket.assigns.user_id,
           session_id: socket.assigns.session_id
         }) do
      {:ok, %{status: :completed, session: %{active_app: active_app}}} ->
        {:noreply,
         socket
         |> assign(active_app: active_app || :allbert, error: nil)
         |> refresh_workspace()}

      {:ok, %{status: :not_found}} ->
        {:noreply,
         socket
         |> assign(active_app: :allbert, error: nil)
         |> refresh_workspace()}

      {:ok, response} ->
        {:noreply, assign(socket, :error, Map.get(response, :message, inspect(response)))}
    end
  end

  def handle_event("workspace_tile_editor_sync", params, socket) do
    {:reply, workspace_tile_editor_reply(params, socket), socket}
  end

  def handle_event("dismiss_workspace_ephemeral", params, socket) do
    surface_id = Map.get(params, "surface-id") || Map.get(params, "surface_id")

    case run_workspace_action(socket, "dismiss_workspace_ephemeral", %{
           surface_id: surface_id,
           dismissed_by: "operator"
         }) do
      {:ok, %{status: :completed}} ->
        {:noreply, refresh_workspace(socket)}

      {:ok, response} ->
        {:noreply, assign(socket, :error, Map.get(response, :message, inspect(response)))}
    end
  end

  def handle_event(
        "revert_tile_revision",
        %{"tile-id" => tile_id, "revision-id" => revision_id},
        socket
      ) do
    {:noreply,
     socket
     |> revert_tile_revision(tile_id, revision_id)
     |> refresh_workspace()}
  end

  def handle_event("toggle_workspace_tile_menu", %{"tile-id" => tile_id}, socket)
      when is_binary(tile_id) and tile_id != "" do
    next_tile_id =
      if socket.assigns.open_tile_menu_id == tile_id do
        nil
      else
        tile_id
      end

    {:noreply, assign(socket, :open_tile_menu_id, next_tile_id)}
  end

  def handle_event("toggle_workspace_tile_menu", _params, socket), do: {:noreply, socket}

  def handle_event("open_tile_inspector", %{"tile-id" => tile_id}, socket)
      when is_binary(tile_id) and tile_id != "" do
    if tile_by_id(socket.assigns.canvas_tiles, tile_id) do
      {:noreply, assign(socket, open_tile_inspector_id: tile_id, open_tile_menu_id: nil)}
    else
      {:noreply, assign(socket, :error, "Tile #{tile_id} is no longer available.")}
    end
  end

  def handle_event("open_tile_inspector", _params, socket), do: {:noreply, socket}

  def handle_event("close_tile_inspector", _params, socket) do
    {:noreply, assign(socket, :open_tile_inspector_id, nil)}
  end

  def handle_event(
        "manage_workspace_tile",
        %{"tile-id" => tile_id, "operation" => operation},
        socket
      )
      when is_binary(tile_id) and tile_id != "" and
             operation in ["pin", "unpin", "remove", "restore"] do
    case run_workspace_action(socket, "manage_workspace_tile", %{
           tile_id: tile_id,
           operation: operation
         }) do
      {:ok, %{status: :completed}} ->
        {:noreply,
         socket
         |> assign(error: nil, open_tile_menu_id: nil, open_tile_inspector_id: nil)
         |> refresh_workspace()}

      {:ok, response} ->
        {:noreply,
         assign(socket,
           error: Map.get(response, :message, inspect(response)),
           open_tile_menu_id: nil
         )}
    end
  end

  def handle_event("manage_workspace_tile", _params, socket) do
    {:noreply, assign(socket, :error, "Invalid workspace tile action.")}
  end

  def handle_event("connect_discovery_candidate", %{"candidate-id" => candidate_id}, socket)
      when is_binary(candidate_id) and candidate_id != "" do
    case run_workspace_action(socket, "mcp_server_connect", %{candidate_id: candidate_id}) do
      {:ok, %{status: :needs_confirmation} = response} ->
        handoff =
          %{}
          |> ApprovalHandoff.pending(response, approval_context(socket))
          |> ApprovalHandoff.to_map()

        {:noreply,
         socket
         |> assign(
           response: response.message,
           status: response.status,
           approval_handoff: handoff,
           approval_lines: ApprovalHandoff.lines(handoff),
           approval_result: nil,
           show_approval_details?: false,
           error: nil
         )
         |> refresh_workspace()}

      {:ok, %{status: :completed} = response} ->
        {:noreply,
         socket
         |> assign(response: response.message, status: response.status, error: nil)
         |> refresh_workspace()}

      {:ok, response} ->
        {:noreply, assign(socket, :error, Map.get(response, :message, inspect(response)))}
    end
  end

  def handle_event("connect_discovery_candidate", _params, socket) do
    {:noreply, assign(socket, :error, "Invalid discovery suggestion.")}
  end

  def handle_event("approve_confirmation", %{"id" => id}, socket) do
    {:noreply, resolve_confirmation(socket, "approve_confirmation", %{id: id})}
  end

  def handle_event("deny_confirmation", %{"id" => id}, socket) do
    {:noreply,
     resolve_confirmation(socket, "deny_confirmation", %{
       id: id,
       reason: "Denied from LiveView approval handoff."
     })}
  end

  @impl true
  def handle_info({:objective_event, _signal}, socket) do
    {:noreply, refresh_objectives(socket)}
  end

  def handle_info({:fragment, %Envelope{} = envelope}, socket) do
    {:noreply, handle_fragment(envelope, socket)}
  end

  def handle_info({:workspace_event, %Signal{} = signal}, socket) do
    {:noreply, handle_workspace_event(signal, socket)}
  end

  def handle_info(:refresh_objectives, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_objectives, 5_000)
    {:noreply, refresh_objectives(socket)}
  end

  def handle_info({:sync_workspace_thread_url, thread_id, canvas_destination}, socket) do
    {:noreply,
     push_patch(socket,
       to: workspace_path(thread_id, canvas_destination),
       replace: true
     )}
  end

  @impl true
  def handle_async(:ask, {:ok, {:ok, response}}, socket) do
    socket =
      socket
      |> assign(
        asking?: false,
        response: response.message,
        status: response.status,
        signal_id: response.signal_id,
        trace_id: Map.get(response, :trace_id),
        approval_handoff: Map.get(response, :approval_handoff),
        approval_lines: ApprovalHandoff.lines(Map.get(response, :approval_handoff)),
        # v0.26a M29: clear composer after a successful turn.
        prompt: ""
      )
      # v0.26a M28: refresh conversation_messages + tiles + ephemerals so the
      # chat timeline accumulates the just-completed turn without a navigation.
      |> refresh_workspace()

    {:noreply, socket}
  end

  def handle_async(:ask, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, asking?: false, error: inspect(reason))}
  end

  def handle_async(:ask, {:exit, reason}, socket) do
    {:noreply, assign(socket, asking?: false, error: "Agent crashed: #{inspect(reason)}")}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :open_tile_inspector_tile,
        tile_by_id(assigns.canvas_tiles, assigns.open_tile_inspector_id)
      )

    ~H"""
    <Layouts.app flash={@flash} content_width="full">
      <section
        id="workspace-shell"
        class={[
          "workspace-shell min-h-screen px-4 py-4 sm:px-6 lg:px-8",
          @workspace_high_contrast? && "workspace-high-contrast",
          @workspace_reduce_motion? && "workspace-reduce-motion"
        ]}
        data-theme={theme_attribute(@workspace_theme)}
        data-workspace-theme={@workspace_theme}
        data-user-id={@user_id}
        data-thread-id={@thread_id}
        data-session-id={@session_id}
        data-active-app={active_app_attribute(@active_app)}
        data-canvas-destination={@canvas_destination}
        data-high-contrast={bool_attribute(@workspace_high_contrast?)}
        data-reduce-motion={bool_attribute(@workspace_reduce_motion?)}
        data-mobile-tab={@workspace_mobile_tab}
        data-launcher-open={bool_attribute(@workspace_launcher_open?)}
        data-maximized-pane={@workspace_maximized_pane}
        data-canvas-focus={bool_attribute(@canvas_focus?)}
        data-offline-enabled={bool_attribute(@workspace_offline_enabled?)}
        data-service-worker-url={~p"/workspace-sw.js"}
        data-service-worker-scope="/workspace"
        data-offline-shell-url={~p"/workspace-offline.html"}
        role="region"
        aria-labelledby="workspace-component-title-workspace-header"
      >
        <div
          id="workspace-offline-banner"
          class="workspace-offline-banner"
          data-state={offline_banner_state(@workspace_offline_enabled?)}
          role="status"
          aria-live="polite"
          hidden={@workspace_offline_enabled?}
        >
          {offline_banner_text(@workspace_offline_enabled?)}
        </div>

        <div id="workspace-mobile-shellbar" class="workspace-mobile-shellbar">
          <button
            id="workspace-launcher-toggle"
            type="button"
            class="workspace-mobile-launcher-button"
            phx-click="toggle_workspace_launcher"
            aria-label="Open workspace launcher"
            aria-controls="workspace-node-workspace-nav-rail"
            aria-expanded={bool_attribute(@workspace_launcher_open?)}
          >
            <.icon name="hero-bars-3-micro" class="size-5" />
          </button>
          <nav
            id="workspace-mobile-tabs"
            class="workspace-mobile-tabs"
            role="tablist"
            aria-label="Workspace sections"
          >
            <button
              :for={tab <- workspace_mobile_tabs()}
              id={"workspace-mobile-tab-#{tab.id}"}
              type="button"
              class={[
                "workspace-mobile-tab",
                @workspace_mobile_tab == tab.id && "workspace-mobile-tab-active"
              ]}
              role="tab"
              aria-selected={bool_attribute(@workspace_mobile_tab == tab.id)}
              aria-controls={tab.controls}
              phx-click="select_workspace_mobile_tab"
              phx-value-tab={tab.id}
            >
              {tab.label}
            </button>
          </nav>
        </div>

        <.live_component
          module={WorkspaceRenderer}
          id="workspace-renderer"
          surface={@workspace_surface}
          renderer_context={renderer_context(assigns)}
          workspace_state={workspace_state(assigns)}
        />

        <.live_component
          :if={@open_tile_inspector_tile}
          module={TileInspector}
          id="workspace-tile-inspector-component"
          tile={@open_tile_inspector_tile}
        />
      </section>
    </Layouts.app>
    """
  end

  defp resolve_confirmation(socket, action_name, params) do
    case Runner.run(action_name, params, approval_context(socket)) do
      {:ok, %{status: :completed, confirmation: confirmation} = response} ->
        handoff = update_handoff_status(socket.assigns.approval_handoff, confirmation)

        socket =
          if pending_confirmation?(confirmation) do
            assign(socket,
              approval_result: approval_resolution_message(response, confirmation),
              approval_handoff: handoff,
              approval_lines: ApprovalHandoff.lines(handoff)
            )
          else
            assign(socket,
              approval_result: approval_resolution_message(response, confirmation),
              approval_handoff: nil,
              approval_lines: [],
              show_approval_details?: false
            )
          end

        socket
        |> refresh_objectives()
        |> refresh_workspace()

      {:ok, response} ->
        assign(socket, approval_result: Map.get(response, :message, inspect(response)))
    end
  end

  defp pending_confirmation?(confirmation), do: confirmation_status(confirmation) == "pending"

  defp confirmation_status(confirmation) when is_map(confirmation) do
    confirmation
    |> Map.get("status", Map.get(confirmation, :status))
    |> to_string()
  end

  defp approval_resolution_message(response, confirmation) do
    message =
      Map.get(response, :message) ||
        Confirmations.status_message(confirmation)

    external_details =
      confirmation
      |> ExternalRequestMetadata.result_details()
      |> Enum.reject(&String.starts_with?(&1, "Body preview:"))

    details =
      external_details ++
        ShellCommandMetadata.result_details(confirmation) ++
        PackageInstallMetadata.result_details(confirmation) ++
        OnlineSkillMetadata.lines(confirmation) ++
        SkillScriptMetadata.result_details(confirmation)

    if details == [], do: message, else: "#{message} #{Enum.join(details, " · ")}"
  end

  defp update_handoff_status(nil, _confirmation), do: nil

  defp update_handoff_status(handoff, confirmation) do
    status = Map.get(confirmation, "status") || Map.get(confirmation, :status)
    Map.put(handoff, :status, status || Map.get(handoff, :status))
  end

  defp approval_context(socket) do
    user_id = socket.assigns.user_id

    %{
      actor: user_id,
      user_id: user_id,
      operator_id: user_id,
      channel: :live_view,
      surface: "AllbertAssistWeb.WorkspaceLive",
      response_target: socket.id
    }
  end

  defp active_objectives(user_id) do
    case Runner.run(
           "list_objectives",
           %{user_id: user_id, status: ["open", "running", "blocked"], limit: 5},
           %{actor: user_id, user_id: user_id, operator_id: user_id, channel: :live_view}
         ) do
      {:ok, %{status: :completed, objectives: objectives}} -> objectives
      _other -> []
    end
  end

  defp refresh_objectives(socket) do
    assign(socket, :active_objectives, active_objectives(socket.assigns.user_id))
  end

  defp resolve_workspace_thread(params, user_id) do
    requested_thread_id = param(params, "thread_id")

    attrs = %{
      user_id: user_id,
      thread_id: requested_thread_id,
      text: "Workspace session"
    }

    case Conversations.resolve_thread(attrs) do
      {:ok, thread} ->
        {thread.id, nil, false}

      {:error, reason} ->
        case Conversations.resolve_thread(%{
               user_id: user_id,
               text: "Workspace session",
               new_thread: true
             }) do
          {:ok, thread} ->
            {thread.id, thread_recovery_notice(reason, requested_thread_id),
             explicit_thread_id?(requested_thread_id)}

          {:error, fallback_reason} ->
            raise "failed to resolve workspace thread: #{inspect(fallback_reason)}"
        end
    end
  end

  defp explicit_thread_id?(thread_id) when is_binary(thread_id), do: true
  defp explicit_thread_id?(_thread_id), do: false

  defp thread_recovery_notice({:thread_not_found, thread_id}, requested_thread_id) do
    "Started a new workspace thread because #{short_thread_id(thread_id || requested_thread_id)} was not found."
  end

  defp thread_recovery_notice(_reason, requested_thread_id) do
    "Started a new workspace thread because #{short_thread_id(requested_thread_id)} could not be opened."
  end

  defp short_thread_id(nil), do: "the requested thread"

  defp short_thread_id(thread_id) when is_binary(thread_id) do
    if String.length(thread_id) > 18 do
      String.slice(thread_id, 0, 14) <> "..."
    else
      thread_id
    end
  end

  defp maybe_sync_thread_url(socket, true, thread_id, canvas_destination) do
    if connected?(socket) do
      Process.send_after(self(), {:sync_workspace_thread_url, thread_id, canvas_destination}, 0)
    end

    socket
  end

  defp maybe_sync_thread_url(socket, _sync?, _thread_id, _canvas_destination), do: socket

  defp resolve_workspace_active_app(user_id, session_id) do
    session_active_app(user_id, session_id) || :allbert
  end

  defp resolve_canvas_destination(params) do
    params
    |> param("destination")
    |> normalize_canvas_destination()
  end

  defp normalize_canvas_destination(nil), do: Layout.default_destination()
  defp normalize_canvas_destination("output"), do: "output"

  defp normalize_canvas_destination("workspace:" <> tool) when tool in @workspace_tools do
    "workspace:#{tool}"
  end

  defp normalize_canvas_destination("app:" <> app_id) do
    case AppRegistry.normalize_app_id(app_id) do
      {:ok, nil} -> "output"
      {:ok, normalized} -> "app:#{normalized}"
      {:error, :unknown_app} -> "output"
    end
  catch
    :exit, _reason -> "output"
  end

  defp normalize_canvas_destination(_destination), do: "output"

  defp assign_canvas_destination(socket, destination) do
    if Map.get(socket.assigns, :canvas_destination) == destination do
      socket
    else
      socket
      |> assign(:canvas_destination, destination)
      |> refresh_workspace()
    end
  end

  defp maybe_assign_mobile_tab(socket, tab) when tab in ["chat", "canvas"] do
    assign(socket, :workspace_mobile_tab, tab)
  end

  defp maybe_assign_mobile_tab(socket, _tab), do: socket

  defp session_active_app(user_id, session_id) do
    case Session.get(user_id, session_id, touch?: true) do
      {:ok, %{active_app: active_app}} -> active_app
      _other -> nil
    end
  end

  defp param(params, key) when is_map(params) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      value when is_binary(value) -> normalize_param(value)
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _other -> nil
    end
  end

  defp normalize_param(value) do
    case String.trim(value) do
      value when value in ["", "nil", "null"] -> nil
      value -> value
    end
  end

  defp handle_workspace_event(%Signal{} = signal, socket) do
    data = signal.data || %{}

    if metadata_value(data, :user_id) == socket.assigns.user_id and
         metadata_value(data, :thread_id) == socket.assigns.thread_id do
      refresh_workspace(socket)
    else
      socket
    end
  end

  defp handle_fragment(%Envelope{} = envelope, socket) do
    if envelope.user_id == socket.assigns.user_id and
         envelope.thread_id == socket.assigns.thread_id do
      refresh_workspace_fragment(socket, envelope)
    else
      socket
    end
  end

  defp refresh_workspace_fragment(socket, %Envelope{} = envelope) do
    if header_badge_fragment?(envelope) do
      put_workspace_badge(socket, envelope)
    else
      refresh_workspace(socket)
    end
  end

  defp header_badge_fragment?(%Envelope{kind: kind, metadata: metadata}) do
    normalize_kind(kind) == "badge_strip" and
      metadata_value(metadata, :placement) == "canvas_header"
  end

  defp put_workspace_badge(socket, %Envelope{} = envelope) do
    badges =
      [envelope | socket.assigns.workspace_badges]
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(5)

    socket
    |> assign(:workspace_badges, badges)
    |> refresh_workspace()
  end

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind
  defp normalize_kind(kind), do: to_string(kind)

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp refresh_workspace(socket) do
    assign(
      socket,
      workspace_assigns(
        socket.assigns.user_id,
        socket.assigns.thread_id,
        socket.assigns.workspace_badges,
        socket.assigns.active_app,
        socket.assigns.canvas_destination
      )
    )
  end

  defp workspace_assigns(user_id, thread_id, workspace_badges, active_app, canvas_destination) do
    tiles = canvas_tiles(thread_id, user_id)
    surfaces = ephemeral_surfaces(thread_id, user_id)
    apps = registered_apps()

    surface_context =
      registered_surface_context(%{
        user_id: user_id,
        thread_id: thread_id,
        session_id: @default_session_id,
        active_app: active_app,
        canvas_destination: canvas_destination
      })

    %{
      canvas_tiles: tiles,
      ephemeral_surfaces: surfaces,
      conversation_messages: conversation_messages(thread_id, user_id),
      recent_threads: recent_threads(user_id),
      registered_apps: apps,
      workspace_badges: workspace_badges,
      workspace_surface:
        WorkspaceCatalog.workspace_tree(
          user_id: user_id,
          thread_id: thread_id,
          canvas_tiles: tiles,
          ephemeral_surfaces: surfaces,
          workspace_badges: workspace_badges,
          active_app: active_app,
          canvas_destination: canvas_destination,
          registered_apps: apps,
          panel_surfaces: surface_context.panel_surfaces,
          surface_catalogs: surface_context.surface_catalogs
        )
    }
  end

  defp canvas_tiles(thread_id, user_id) do
    case Workspace.canvas_tiles(thread_id, user_id) do
      {:ok, tiles} -> tiles
      {:error, _reason} -> []
    end
  end

  defp ephemeral_surfaces(thread_id, user_id) do
    case Workspace.ephemeral_surfaces(thread_id, user_id) do
      {:ok, surfaces} -> surfaces
      {:error, _reason} -> []
    end
  end

  defp conversation_messages(thread_id, user_id) do
    with {:ok, thread} <- Conversations.get_thread(user_id, thread_id) do
      Conversations.list_messages(thread, limit: 12)
    else
      _error -> []
    end
  end

  defp recent_threads(user_id) do
    Conversations.list_threads(user_id, limit: 8)
  end

  defp registered_apps do
    case AppRegistry.registered_apps() do
      [] -> [%{app_id: :allbert, display_name: "Allbert"}]
      apps -> ensure_allbert_app(apps)
    end
  catch
    :exit, _reason -> [%{app_id: :allbert, display_name: "Allbert"}]
  end

  defp ensure_allbert_app(apps) do
    if Enum.any?(apps, &(Map.get(&1, :app_id) == :allbert)) do
      apps
    else
      [%{app_id: :allbert, display_name: "Allbert"} | apps]
    end
  end

  defp registered_surface_context(context) do
    providers = registered_surface_providers()

    %{
      panel_surfaces: Enum.flat_map(providers, &provider_panel_surfaces(&1, context)),
      surface_catalogs:
        providers
        |> Enum.map(&{Map.get(&1, :app_id), Map.get(&1, :catalog, [])})
        |> Map.new()
    }
  end

  defp registered_surface_providers do
    case AppRegistry.registered_surface_providers() do
      [] -> [core_surface_provider()]
      providers -> ensure_core_surface_provider(providers)
    end
  catch
    :exit, _reason -> [core_surface_provider()]
  end

  defp ensure_core_surface_provider(providers) do
    providers =
      Enum.reject(providers, fn provider ->
        app_id = Map.get(provider, :app_id) || Map.get(provider, "app_id")
        app_id in [:allbert, "allbert"]
      end)

    [core_surface_provider() | providers]
  end

  defp core_surface_provider do
    %{
      app_id: :allbert,
      module: CoreApp,
      surfaces: CoreApp.surfaces(),
      catalog: CoreApp.surface_catalog()
    }
  end

  defp provider_panel_surfaces(provider, context) do
    provider
    |> hydrated_panel_surfaces(context)
    |> panel_surface_list(provider)
  end

  defp hydrated_panel_surfaces(%{module: module}, context)
       when is_atom(module) and not is_nil(module) do
    if function_exported?(module, :workspace_panel_surfaces, 1) do
      module.workspace_panel_surfaces(context)
    end
  rescue
    _exception -> nil
  catch
    :exit, _reason -> nil
  end

  defp hydrated_panel_surfaces(_provider, _context), do: nil

  defp panel_surface_list({:ok, surfaces}, provider), do: panel_surface_list(surfaces, provider)

  defp panel_surface_list(surfaces, _provider) when is_list(surfaces),
    do: filter_panel_surfaces(surfaces)

  defp panel_surface_list(_surfaces, provider), do: provider_static_panel_surfaces(provider)

  defp provider_static_panel_surfaces(provider) do
    provider
    |> Map.get(:surfaces, [])
    |> filter_panel_surfaces()
  end

  defp filter_panel_surfaces(surfaces), do: Enum.filter(surfaces, &match?(%{kind: :panel}, &1))

  defp tile_by_id(tiles, tile_id) when is_list(tiles) and is_binary(tile_id) do
    Enum.find(tiles, &(Map.get(&1, :id) == tile_id || Map.get(&1, "id") == tile_id))
  end

  defp tile_by_id(_tiles, _tile_id), do: nil

  defp workspace_theme do
    case Settings.get("workspace.theme.mode") do
      {:ok, theme} when theme in ["dark", "light", "system"] -> theme
      _other -> "system"
    end
  end

  defp workspace_high_contrast? do
    case Settings.get("workspace.accessibility.high_contrast") do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp workspace_reduce_motion? do
    case Settings.get("workspace.accessibility.reduce_motion") do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp workspace_offline_enabled? do
    case Settings.get("workspace.offline.enabled") do
      {:ok, false} -> false
      _other -> true
    end
  end

  defp workspace_indexeddb_quota_bytes do
    megabytes =
      case Settings.get("workspace.offline.indexeddb_quota_mb") do
        {:ok, value} when is_integer(value) -> value
        _other -> 32
      end

    megabytes * 1_048_576
  end

  defp workspace_canvas_max_tiles_per_thread do
    case Settings.get("workspace.canvas.max_tiles_per_thread") do
      {:ok, value} when is_integer(value) -> value
      _other -> 64
    end
  end

  defp workspace_canvas_tile_body_max_bytes do
    case Settings.get("workspace.canvas.tile_body_max_bytes") do
      {:ok, value} when is_integer(value) and value > 0 -> value
      _other -> 65_536
    end
  end

  defp workspace_tile_editor_reply(params, socket) do
    with true <- socket.assigns.workspace_offline_enabled? || {:error, :offline_disabled},
         {:ok, %{status: status, result: result}}
         when status in [:completed, :conflict] <-
           run_workspace_action(
             socket,
             "record_workspace_offline_update",
             Map.merge(params, %{
               "thread_id" => socket.assigns.thread_id,
               "max_bytes" => socket.assigns.workspace_indexeddb_quota_bytes
             })
           ) do
      %{
        status: if(result.conflict?, do: "conflict", else: "received"),
        tile_id: result.tile.id,
        revision_id: result.revision.id,
        current_revision_id: result.tile.current_revision_id,
        conflict_count: result.conflict_count,
        max_bytes: socket.assigns.workspace_indexeddb_quota_bytes
      }
    else
      {:error, reason} ->
        %{status: "rejected", reason: inspect(reason)}

      {:ok, response} ->
        %{status: "rejected", reason: inspect(Map.get(response, :reason, response.status))}
    end
  end

  defp submit_workspace_prompt(socket, prompt) when is_binary(prompt) do
    prompt = String.trim(prompt)

    if prompt == "" do
      socket
    else
      do_submit_workspace_prompt(socket, prompt)
    end
  end

  defp submit_workspace_prompt(socket, _prompt), do: socket

  defp do_submit_workspace_prompt(socket, prompt) do
    runtime_request = %{
      text: prompt,
      channel: :live_view,
      user_id: socket.assigns.user_id,
      operator_id: socket.assigns.user_id,
      thread_id: socket.assigns.thread_id,
      session_id: socket.assigns.session_id,
      active_app: socket.assigns.active_app,
      canvas_destination: socket.assigns.canvas_destination
    }

    socket
    |> assign(
      prompt: prompt,
      response: nil,
      error: nil,
      asking?: true,
      status: nil,
      signal_id: nil,
      trace_id: nil,
      approval_handoff: nil,
      approval_lines: [],
      approval_result: nil,
      show_approval_details?: false
    )
    |> start_async(:ask, fn ->
      Runtime.submit_user_input(runtime_request)
    end)
  end

  defp dismiss_intent_surface(socket, params, _dismissed_by) do
    case optional_param(params, "surface-id") do
      nil ->
        socket

      surface_id ->
        case run_workspace_action(socket, "dismiss_workspace_ephemeral", %{
               surface_id: surface_id,
               dismissed_by: "operator"
             }) do
          {:ok, %{status: :completed}} ->
            socket

          {:ok, %{reason: :not_found}} ->
            socket

          {:ok, response} ->
            assign(socket, :error, Map.get(response, :message, inspect(response)))
        end
    end
  end

  defp required_param(params, name) do
    case optional_param(params, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_required, name}}
    end
  end

  defp optional_param(params, name) when is_map(params) do
    underscore = String.replace(name, "-", "_")

    [
      name,
      underscore,
      existing_atom(name),
      existing_atom(underscore)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(fn key ->
      case Map.get(params, key) do
        value when is_binary(value) -> String.trim(value)
        value when is_atom(value) -> Atom.to_string(value)
        _other -> nil
      end
    end)
  end

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp run_workspace_action(socket, action_name, params) do
    Runner.run(action_name, params, %{
      actor: socket.assigns.user_id,
      user_id: socket.assigns.user_id,
      operator_id: socket.assigns.user_id,
      thread_id: socket.assigns.thread_id,
      session_id: socket.assigns.session_id,
      active_app: socket.assigns.active_app,
      channel: :live_view
    })
  end

  defp revert_tile_revision(socket, tile_id, revision_id) do
    case run_workspace_action(
           socket,
           "revert_tile_revision",
           %{tile_id: tile_id, revision_id: revision_id}
         ) do
      {:ok, %{status: :completed}} ->
        socket

      {:ok, response} ->
        assign(socket, :error, Map.get(response, :message, inspect(response)))
    end
  end

  # v0.26a M34 / v0.35: theme cycles system → dark → light → system so operators
  # reach all three workspace.theme.mode values from the AppBar without dropping
  # to `mix allbert.settings`. Default boot starts at "system" → dark to
  # preserve the prior light↔dark first-click semantics.
  defp next_workspace_theme("system"), do: "dark"
  defp next_workspace_theme("dark"), do: "light"
  defp next_workspace_theme("light"), do: "system"
  defp next_workspace_theme(_theme), do: "dark"

  defp workspace_mobile_tabs do
    [
      %{id: "chat", label: "Chat", controls: "workspace-node-workspace-chat"},
      %{id: "canvas", label: "Canvas", controls: "workspace-node-workspace-canvas-region"}
    ]
  end

  defp bool_attribute(true), do: "true"
  defp bool_attribute(false), do: "false"

  defp active_app_attribute(app) when is_atom(app), do: Atom.to_string(app)
  defp active_app_attribute(app) when is_binary(app), do: app
  defp active_app_attribute(_app), do: ""

  defp offline_banner_state(true), do: "online"
  defp offline_banner_state(false), do: "disabled"

  defp offline_banner_text(true) do
    "Working offline — your shell is cached and changes will sync when you reconnect."
  end

  defp offline_banner_text(false), do: "Offline mode disabled."

  defp theme_attribute("dark"), do: "dark"
  defp theme_attribute("light"), do: "light"
  defp theme_attribute(_theme), do: nil

  defp renderer_context(assigns) do
    %{
      user_id: assigns.user_id,
      thread_id: assigns.thread_id,
      active_objectives: assigns.active_objectives,
      conversation_messages: assigns.conversation_messages,
      recent_threads: assigns.recent_threads,
      registered_apps: assigns.registered_apps,
      workspace_mobile_tab: assigns.workspace_mobile_tab,
      canvas_destination: assigns.canvas_destination,
      canvas_tiles: assigns.canvas_tiles,
      ephemeral_surfaces: assigns.ephemeral_surfaces,
      workspace_badges: assigns.workspace_badges,
      workspace_theme: assigns.workspace_theme,
      workspace_high_contrast?: assigns.workspace_high_contrast?,
      workspace_reduce_motion?: assigns.workspace_reduce_motion?,
      workspace_offline_enabled?: assigns.workspace_offline_enabled?,
      workspace_indexeddb_quota_bytes: assigns.workspace_indexeddb_quota_bytes,
      workspace_canvas_max_tiles_per_thread: assigns.workspace_canvas_max_tiles_per_thread,
      open_tile_menu_id: assigns.open_tile_menu_id,
      active_app: assigns.active_app,
      composer_max_bytes: assigns.composer_max_bytes,
      workspace_overflow_open?: assigns.workspace_overflow_open?,
      workspace_maximized_pane: assigns.workspace_maximized_pane,
      canvas_focus?: assigns.canvas_focus?,
      workspace_launcher_open?: assigns.workspace_launcher_open?
    }
  end

  defp workspace_state(assigns) do
    %{
      prompt: assigns.prompt,
      prompt_placeholder: assigns.prompt_placeholder,
      response: assigns.response,
      error: assigns.error,
      thread_notice: assigns.thread_notice,
      asking?: assigns.asking?,
      status: assigns.status,
      signal_id: assigns.signal_id,
      trace_id: assigns.trace_id,
      approval_handoff: assigns.approval_handoff,
      approval_lines: assigns.approval_lines,
      approval_result: assigns.approval_result,
      show_approval_details?: assigns.show_approval_details?,
      thread_switcher_open?: assigns.thread_switcher_open?,
      workspace_overflow_open?: assigns.workspace_overflow_open?
    }
  end

  defp workspace_path(thread_id, canvas_destination) do
    query =
      if canvas_destination == "output" do
        [thread_id: thread_id]
      else
        [thread_id: thread_id, destination: canvas_destination]
      end

    ~p"/workspace?#{query}"
  end
end
