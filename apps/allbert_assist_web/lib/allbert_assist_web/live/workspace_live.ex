defmodule AllbertAssistWeb.WorkspaceLive do
  @moduledoc """
  Workspace LiveView for talking to the Allbert runtime boundary.

  Routes user prompts through `AllbertAssist.Runtime` asynchronously via
  `start_async/3` so the UI stays responsive.
  """
  use AllbertAssistWeb, :live_view

  require Logger

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.CoreApp
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Artifacts.MediaRetention
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.LocalSurface
  alias AllbertAssist.Confirmations

  alias AllbertAssist.Confirmations.{
    ExternalRequestMetadata,
    OnlineSkillMetadata,
    PackageInstallMetadata,
    ShellCommandMetadata,
    SkillScriptMetadata
  }

  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.UnifiedHistory
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Resources.ImageBounds
  alias AllbertAssist.Resources.ImageMetadata
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.MediaOutputs
  alias AllbertAssist.Runtime.Paths, as: RuntimePaths
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Session
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Surface.EventRecorder
  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertAssist.Theme.Layout
  alias AllbertAssist.Workspace
  alias AllbertAssist.Workspace.Catalog, as: WorkspaceCatalog
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssistWeb.SignalBridge
  alias AllbertAssistWeb.Workspace.Components.Patterns
  alias AllbertAssistWeb.Workspace.Components.TileInspector
  alias AllbertAssistWeb.Workspace.Renderer, as: WorkspaceRenderer
  alias Jido.Signal

  @default_user_id "local"
  @default_external_user_id "web-local"
  @default_identity_map [
    %{"external_user_id" => @default_external_user_id, "user_id" => @default_user_id}
  ]
  @default_prompt_placeholder "Ask Allbert anything…"
  @workspace_tools ~w(onboard create plan_build plan_runs discover marketplace calendar mail github jobs objectives confirmations security intents models channels surface_policy settings)
  @voice_capture_accept ~w(.wav .mp3 .m4a .ogg .webm .flac)
  @voice_capture_upload_accept ~w(audio/*)
  @voice_capture_duration_skew_ms 5_000
  @image_input_accept ~w(.png .jpg .jpeg .webp)
  @image_input_upload_accept ~w(image/*)

  @impl true
  def mount(params, session, socket) do
    identity = resolve_live_view_identity(params, session)
    user_id = identity.user_id
    session_id = identity.session_id
    {thread_id, thread_notice, sync_thread_url?} = resolve_workspace_thread(params, user_id)
    active_app = resolve_workspace_active_app(user_id, session_id)
    canvas_destination = resolve_canvas_destination(params)
    artifacts_browser_filters = resolve_artifacts_browser_filters(params)
    settings = workspace_settings_snapshot(user_id, session_id)

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
        artifacts_browser_filters: artifacts_browser_filters,
        workspace_theme: workspace_theme(settings),
        workspace_high_contrast?: workspace_high_contrast?(settings),
        workspace_reduce_motion?: workspace_reduce_motion?(settings),
        workspace_mobile_tab: "chat",
        workspace_offline_enabled?: workspace_offline_enabled?(settings),
        workspace_indexeddb_quota_bytes: workspace_indexeddb_quota_bytes(settings),
        workspace_canvas_max_tiles_per_thread: workspace_canvas_max_tiles_per_thread(settings),
        voice_capture: voice_capture_idle(settings),
        image_input: image_input_idle(settings),
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
        composer_max_bytes: workspace_canvas_tile_body_max_bytes(settings),
        workspace_overflow_open?: false,
        workspace_maximized_pane: nil,
        canvas_focus?: canvas_destination != "output"
      )
      |> allow_upload(:voice_capture,
        accept: @voice_capture_upload_accept,
        max_entries: 1,
        max_file_size: voice_capture_max_bytes(settings)
      )
      |> allow_upload(:image_input,
        accept: @image_input_upload_accept,
        max_entries: 1,
        max_file_size: image_input_max_bytes(settings)
      )
      |> assign(
        workspace_assigns(
          user_id,
          session_id,
          thread_id,
          [],
          active_app,
          canvas_destination,
          artifacts_browser_filters
        )
      )
      |> maybe_sync_thread_url(sync_thread_url?, thread_id, canvas_destination)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{} = params, _uri, socket) do
    destination = resolve_canvas_destination(params)

    socket =
      socket
      |> assign_canvas_destination(destination)
      |> assign(:page_title, workspace_page_title(destination))
      |> assign_artifacts_browser_filters(resolve_artifacts_browser_filters(params))
      |> assign(:workspace_overflow_open?, false)
      |> maybe_assign_mobile_tab(param(params, "tab"))

    {:noreply, socket}
  end

  @impl true
  def handle_event("ask", %{"prompt" => prompt}, socket) do
    {:noreply, submit_workspace_prompt(socket, prompt)}
  end

  def handle_event("ask", _params, socket), do: {:noreply, socket}

  def handle_event("accept_intent_handoff", %{"destination" => destination} = params, socket)
      when is_binary(destination) and destination != "" do
    canvas_destination = normalize_canvas_destination(destination)

    socket =
      socket
      |> dismiss_intent_surface(params, "handoff_accepted")
      |> assign_canvas_destination(canvas_destination)
      |> push_patch(to: workspace_path(socket.assigns.thread_id, canvas_destination))

    {:noreply, socket}
  end

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

  def handle_event("dismiss_approval_handoff", _params, socket) do
    {:noreply,
     assign(socket,
       approval_handoff: nil,
       approval_lines: [],
       show_approval_details?: false
     )}
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

  def handle_event("request_voice_capture", _params, socket) do
    params = %{
      session_id: socket.assigns.session_id,
      thread_id: socket.assigns.thread_id,
      user_id: socket.assigns.user_id
    }

    case run_workspace_action(socket, "capture_workspace_voice", params) do
      {:ok, %{status: :needs_confirmation} = response} ->
        {:noreply,
         socket
         |> assign(:voice_capture, Map.put(socket.assigns.voice_capture, :status, :pending))
         |> assign_confirmation_handoff(response)}

      {:ok, %{status: :completed, output_data: output_data} = response} ->
        {:noreply,
         socket
         |> assign(:voice_capture, approved_voice_capture(output_data, %{}))
         |> assign(response: response_text(response), status: response.status, error: nil)}

      {:ok, response} ->
        {:noreply,
         assign(socket,
           voice_capture: voice_capture_idle(workspace_settings_snapshot()),
           error: Map.get(response, :message, inspect(response))
         )}
    end
  end

  def handle_event("validate_voice_capture", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_voice_capture_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :voice_capture, ref)}
  end

  def handle_event("cancel_voice_capture_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_image_input_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :image_input, ref)}
  end

  def handle_event("cancel_image_input_upload", _params, socket), do: {:noreply, socket}

  def handle_event("submit_voice_capture", _params, socket) do
    {:noreply, submit_voice_capture(socket)}
  end

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
        {:noreply,
         assign(socket, :error, "Could not start a new conversation: #{inspect(reason)}")}
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
        # Push the new theme so the ThemeSync hook updates <html data-theme> in step
        # with #workspace-shell (v0.61 M10.3 P1 — avoids a mixed light/dark surface).
        {:noreply,
         socket
         |> assign(:workspace_theme, theme)
         |> push_event("allbert:set-theme", %{theme: theme})}

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
     |> assign(
       canvas_destination: destination,
       workspace_mobile_tab: "canvas",
       canvas_focus?: true
     )
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

  def handle_event("plan_build_cancel_run", %{"objective-id" => objective_id}, socket)
      when is_binary(objective_id) and objective_id != "" do
    params = %{
      objective_id: objective_id,
      user_id: socket.assigns.user_id,
      reason: "Cancelled from Plan/Build workspace panel."
    }

    case run_workspace_action(socket, "cancel_plan_run", params) do
      {:ok, %{status: :cancelled} = response} ->
        {:noreply,
         socket
         |> assign(response: response_text(response), error: nil)
         |> refresh_objectives()
         |> refresh_workspace()}

      {:ok, response} ->
        {:noreply, assign(socket, :error, Map.get(response, :message, inspect(response)))}
    end
  end

  def handle_event("plan_build_cancel_run", _params, socket), do: {:noreply, socket}

  def handle_event("plan_build_start_run", %{"workflow-id" => workflow_id}, socket)
      when is_binary(workflow_id) and workflow_id != "" do
    params = %{workflow_id: workflow_id, user_id: socket.assigns.user_id}

    # start_plan_run is confirmation-required (permission :workflow_run_start); the
    # first invocation returns needs_confirmation and surfaces through the normal
    # workspace approval handoff. v0.61 M10.3 P0-5 wires the previously-unhandled
    # button so it no longer crashes the LiveView on click.
    case run_workspace_action(socket, "start_plan_run", params) do
      {:ok, %{status: :needs_confirmation} = response} ->
        {:noreply,
         socket
         |> assign(response: response_text(response), error: nil)
         |> assign_confirmation_handoff(response)}

      {:ok, response} ->
        {:noreply, assign(socket, :error, Map.get(response, :message, inspect(response)))}
    end
  end

  def handle_event("plan_build_start_run", _params, socket), do: {:noreply, socket}

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
        {:noreply, refresh_workspace_runtime(socket)}

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
        {:noreply,
         socket
         |> assign_confirmation_handoff(response)}

      {:ok, %{status: :completed} = response} ->
        {:noreply,
         socket
         |> assign(response: response_text(response), status: response.status, error: nil)
         |> refresh_workspace()}

      {:ok, response} ->
        {:noreply, assign(socket, :error, Map.get(response, :message, inspect(response)))}
    end
  end

  def handle_event("connect_discovery_candidate", _params, socket) do
    {:noreply, assign(socket, :error, "Invalid discovery suggestion.")}
  end

  def handle_event("discover_mcp_integration", %{"integration" => integration}, socket)
      when integration in ["calendar", "mail", "github"] do
    case run_workspace_action(socket, "find_tools", %{
           query: "#{integration} MCP server",
           limit: 8
         }) do
      {:ok, %{status: :completed} = response} ->
        {:noreply,
         socket
         |> assign(response: response_text(response), status: response.status, error: nil)
         |> refresh_workspace()}

      {:ok, response} ->
        {:noreply, assign(socket, :error, Map.get(response, :message, inspect(response)))}
    end
  end

  def handle_event("discover_mcp_integration", _params, socket) do
    {:noreply, assign(socket, :error, "Invalid MCP integration discovery request.")}
  end

  def handle_event("run_mcp_integration_action", params, socket) do
    with {:ok, action_name, action_params} <- mcp_integration_action_params(params) do
      case run_workspace_action(socket, action_name, action_params) do
        {:ok, %{status: :needs_confirmation} = response} ->
          {:noreply,
           socket
           |> assign_confirmation_handoff(response)}

        {:ok, %{status: :completed} = response} ->
          {:noreply,
           socket
           |> assign(response: response_text(response), status: response.status, error: nil)
           |> refresh_workspace()}

        {:ok, response} ->
          {:noreply, assign(socket, :error, Map.get(response, :message, inspect(response)))}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, :error, reason)}
    end
  end

  def handle_event("run_marketplace_action", params, socket) do
    with {:ok, action_name, action_params} <- marketplace_action_params(params) do
      case run_workspace_action(socket, action_name, action_params) do
        {:ok, %{status: :needs_confirmation} = response} ->
          {:noreply,
           socket
           |> assign_confirmation_handoff(response)}

        {:ok, %{status: :completed} = response} ->
          {:noreply,
           socket
           |> assign(response: response_text(response), status: response.status, error: nil)
           |> refresh_workspace()}

        {:ok, response} ->
          {:noreply, assign(socket, :error, Map.get(response, :message, inspect(response)))}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, :error, reason)}
    end
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
        response: response_text(response),
        status: response.status,
        signal_id: response.signal_id,
        trace_id: Map.get(response, :trace_id),
        approval_handoff: Map.get(response, :approval_handoff),
        approval_lines: ApprovalHandoff.lines(Map.get(response, :approval_handoff)),
        # v0.26a M29: clear composer after a successful turn.
        prompt: ""
      )
      |> refresh_after_runtime_response(response)

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
      <div class="workspace-with-sidebar" data-active-page={workspace_nav_key(@canvas_destination)}>
        <Layouts.product_sidebar active={workspace_nav_key(@canvas_destination)} />
        <section
          id="workspace-shell"
          class={[
            "workspace-shell min-h-screen px-4 py-4 sm:px-6 lg:px-8",
            @workspace_high_contrast? && "workspace-high-contrast",
            @workspace_reduce_motion? && "workspace-reduce-motion"
          ]}
          data-theme={theme_attribute(@workspace_theme)}
          data-operator-shell="workspace"
          data-workspace-shell="workspace"
          data-layout-mode="chat-primary"
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
          data-canvas-drawer={canvas_drawer_state(@canvas_focus?)}
          data-offline-enabled={bool_attribute(@workspace_offline_enabled?)}
          data-service-worker-url={~p"/workspace-sw.js"}
          data-service-worker-scope="/workspace"
          data-offline-shell-url={~p"/workspace-offline.html"}
          role="region"
          aria-labelledby="workspace-component-title-workspace-header"
        >
          <Patterns.status_callout
            id="workspace-offline-banner"
            class="workspace-offline-banner"
            tone="warning"
            message={offline_banner_text(@workspace_offline_enabled?)}
            data-state={offline_banner_state(@workspace_offline_enabled?)}
            hidden={@workspace_offline_enabled?}
          />

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
      </div>
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
        |> maybe_update_voice_capture_from_confirmation(response, confirmation)
        |> maybe_persist_approval_media_response(response)
        |> refresh_objectives()
        |> refresh_workspace()

      {:ok, response} ->
        assign(socket, approval_result: Map.get(response, :message, inspect(response)))
    end
  end

  defp assign_confirmation_handoff(socket, response) do
    handoff =
      %{}
      |> ApprovalHandoff.pending(response, approval_context(socket))
      |> ApprovalHandoff.to_map()

    assign(socket,
      response: response_text(response),
      status: response.status,
      approval_handoff: handoff,
      approval_lines: ApprovalHandoff.lines(handoff),
      approval_result: nil,
      show_approval_details?: false,
      error: nil
    )
  end

  defp maybe_persist_approval_media_response(socket, response) do
    media_outputs = response |> Map.get(:media_outputs, []) |> MediaOutputs.persistable()

    if media_outputs == [],
      do: socket,
      else: persist_approval_media_response(socket, response, media_outputs)
  end

  defp persist_approval_media_response(socket, response, media_outputs) do
    with {:ok, thread} <-
           Conversations.get_thread(socket.assigns.user_id, socket.assigns.thread_id) do
      attrs = approval_media_message_attrs(socket, response, media_outputs)

      _result =
        Conversations.append_assistant_message(thread, approval_media_message(response), attrs)
    end

    socket
  end

  defp approval_media_message_attrs(socket, response, media_outputs) do
    %{
      action_log: approval_media_action_log(response),
      metadata: approval_media_metadata(socket, media_outputs)
    }
  end

  defp approval_media_action_log(response) do
    %{
      status: Map.get(response, :status),
      actions: Map.get(response, :actions, [])
    }
    |> Redactor.redact()
  end

  defp approval_media_metadata(socket, media_outputs) do
    metadata = %{
      channel: :live_view,
      session_id: socket.assigns.session_id,
      media_outputs: media_outputs
    }

    if is_nil(socket.assigns.active_app),
      do: metadata,
      else: Map.put(metadata, :active_app, socket.assigns.active_app)
  end

  defp approval_media_message(response) do
    output_data = Map.get(response, :output_data, %{}) || %{}

    Map.get(output_data, :message) ||
      Map.get(output_data, "message") ||
      Map.get(response, :message) ||
      "Generated media output."
  end

  defp maybe_update_voice_capture_from_confirmation(socket, response, confirmation) do
    if confirmation_target_action(confirmation) == "capture_workspace_voice" do
      case confirmation_status(confirmation) do
        "approved" ->
          assign(
            socket,
            :voice_capture,
            approved_voice_capture(Map.get(response, :output_data), confirmation)
          )

        "denied" ->
          assign(socket, :voice_capture, voice_capture_idle(workspace_settings_snapshot()))

        _status ->
          socket
      end
    else
      socket
    end
  end

  defp confirmation_target_action(confirmation) when is_map(confirmation) do
    get_in(confirmation, ["target_action", "name"]) ||
      get_in(confirmation, [:target_action, :name])
  end

  defp mcp_integration_action_params(%{
         "action-name" => "mcp_read_resource",
         "server-id" => server_id,
         "resource-uri" => uri
       })
       when server_id != "" and uri != "" do
    {:ok, "mcp_read_resource",
     %{
       server_id: server_id,
       uri: uri,
       downstream_consumer: "mcp_resource_reader"
     }}
  end

  defp mcp_integration_action_params(
         %{
           "action-name" => "mcp_call_tool",
           "server-id" => server_id,
           "tool-name" => tool_name
         } = params
       )
       when server_id != "" and tool_name != "" do
    {:ok, "mcp_call_tool",
     %{
       server_id: server_id,
       tool_name: tool_name,
       arguments: mcp_integration_arguments(params),
       downstream_consumer: "workspace_mcp_panel"
     }}
  end

  defp mcp_integration_action_params(_params),
    do: {:error, "Invalid MCP integration action."}

  defp marketplace_action_params(%{"action-name" => action_name, "entry-id" => entry_id} = params)
       when action_name in [
              "inspect_marketplace_entry",
              "install_marketplace_bundle",
              "rollback_marketplace_install",
              "verify_marketplace_bundle_hash"
            ] and entry_id != "" do
    {:ok, action_name,
     %{
       entry_id: entry_id
     }
     |> maybe_put_marketplace_version(Map.get(params, "version"))}
  end

  defp marketplace_action_params(_params), do: {:error, "Invalid marketplace action."}

  defp maybe_put_marketplace_version(params, nil), do: params
  defp maybe_put_marketplace_version(params, ""), do: params
  defp maybe_put_marketplace_version(params, version), do: Map.put(params, :version, version)

  defp mcp_integration_arguments(%{
         "integration" => "calendar",
         "integration-action" => "calendar_read"
       }),
       do: %{"range" => "today", "source" => "workspace_panel"}

  defp mcp_integration_arguments(
         %{
           "integration" => "calendar",
           "integration-action" => "calendar_effect"
         } = params
       ) do
    %{
      "summary" => string_param(params, "summary"),
      "start" => string_param(params, "start"),
      "end" => string_param(params, "end"),
      "source" => "workspace_panel"
    }
    |> put_optional_string_arg("calendar_id", params, "calendar_id")
  end

  defp mcp_integration_arguments(%{
         "integration" => "mail",
         "integration-action" => "mail_read"
       }),
       do: %{"limit" => 10, "source" => "workspace_panel"}

  defp mcp_integration_arguments(
         %{
           "integration" => "mail",
           "integration-action" => "mail_effect"
         } = params
       ),
       do: %{
         "message_id" => string_param(params, "message_id"),
         "body" => string_param(params, "body"),
         "source" => "workspace_panel"
       }

  defp mcp_integration_arguments(%{
         "integration" => "github",
         "integration-action" => "github_read"
       }),
       do: %{"query" => "is:open", "source" => "workspace_panel"}

  defp mcp_integration_arguments(
         %{
           "integration" => "github",
           "integration-action" => "github_effect"
         } = params
       ),
       do: %{
         "target" => string_param(params, "target"),
         "body" => string_param(params, "body"),
         "source" => "workspace_panel"
       }

  defp mcp_integration_arguments(_params), do: %{"source" => "workspace_panel"}

  defp string_param(params, key, default \\ "") do
    case Map.get(params, key, default) do
      value when is_binary(value) -> value
      nil -> default
      value -> to_string(value)
    end
  end

  defp put_optional_string_arg(map, key, params, param_key) do
    value = string_param(params, param_key)

    if String.trim(value) == "" do
      map
    else
      Map.put(map, key, value)
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
    ContextBuilder.live_view_context(socket, surface: "AllbertAssistWeb.WorkspaceLive")
  end

  defp workspace_artifact_context(socket) do
    ContextBuilder.live_view_context(socket, surface: "AllbertAssistWeb.WorkspaceLive")
  end

  defp active_objectives(user_id) do
    case Runner.run(
           "list_objectives",
           %{user_id: user_id, statuses: ["open", "running", "blocked"], limit: 5},
           ContextBuilder.live_view_context(%{user_id: user_id},
             surface: "AllbertAssistWeb.WorkspaceLive"
           )
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
    "Started a new workspace conversation because #{short_thread_id(thread_id || requested_thread_id)} was not found."
  end

  defp thread_recovery_notice(_reason, requested_thread_id) do
    "Started a new workspace conversation because #{short_thread_id(requested_thread_id)} could not be opened."
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

  defp resolve_live_view_identity(params, session) do
    external_user_id = live_view_external_user_id(params, session)
    identity_map = live_view_identity_map(session)
    user_id = resolved_live_view_user_id(external_user_id, identity_map)

    %{
      external_user_id: external_user_id,
      user_id: user_id,
      session_id: Channels.derive_session_id("live_view", external_user_id, nil)
    }
  end

  defp live_view_external_user_id(params, session) do
    session_string(session, "live_view_external_user_id") ||
      first_param(params, ~w(external_user_id user)) ||
      @default_external_user_id
  end

  defp live_view_identity_map(session) do
    case session_value(session, "live_view_identity_map") do
      entries when is_list(entries) -> entries
      _other -> @default_identity_map
    end
  end

  defp resolved_live_view_user_id(external_user_id, identity_map) do
    case Identity.resolve("live_view", external_user_id, identity_map) do
      {:ok, user_id} -> user_id
      {:error, _reason} -> default_live_view_user_id()
    end
  end

  defp default_live_view_user_id do
    case Identity.resolve("live_view", @default_external_user_id, @default_identity_map) do
      {:ok, user_id} -> user_id
      {:error, _reason} -> @default_user_id
    end
  end

  defp resolve_workspace_active_app(user_id, session_id) do
    session_active_app(user_id, session_id) || :allbert
  end

  defp resolve_canvas_destination(params) do
    params
    |> param("destination")
    |> normalize_canvas_destination()
  end

  defp resolve_artifacts_browser_filters(params) do
    %{
      mime: first_param(params, ~w(artifact_type artifact_mime type mime)),
      origin: first_param(params, ~w(artifact_origin origin)),
      thread_id: first_param(params, ~w(artifact_thread thread thread_id)),
      since: first_param(params, ~w(artifact_since since)),
      retention: first_param(params, ~w(artifact_retention retention)),
      lifecycle: first_param(params, ~w(artifact_lifecycle lifecycle)),
      limit: artifacts_filter_limit(first_param(params, ~w(artifact_limit limit)))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
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
      |> maybe_open_canvas_drawer(destination)
      |> refresh_workspace()
    end
  end

  defp maybe_open_canvas_drawer(socket, "output"), do: socket
  defp maybe_open_canvas_drawer(socket, _destination), do: assign(socket, :canvas_focus?, true)

  defp assign_artifacts_browser_filters(socket, filters) do
    if Map.get(socket.assigns, :artifacts_browser_filters, %{}) == filters do
      socket
    else
      socket
      |> assign(:artifacts_browser_filters, filters)
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

  defp first_param(params, keys), do: Enum.find_value(keys, &param(params, &1))

  defp session_string(session, key) do
    case session_value(session, key) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _other -> nil
    end
  end

  defp session_value(session, key) when is_map(session) do
    Map.get(session, key) || Map.get(session, String.to_atom(key))
  end

  defp session_value(_session, _key), do: nil

  defp artifacts_filter_limit(nil), do: nil

  defp artifacts_filter_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} when value > 0 -> value
      _other -> nil
    end
  end

  defp artifacts_filter_limit(_limit), do: nil

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
      refresh_after_workspace_event(socket, signal)
    else
      socket
    end
  end

  defp refresh_after_workspace_event(socket, %Signal{
         type: "allbert.workspace.tile." <> _event,
         data: data
       }) do
    if metadata_value(data, :kind) == "objective_card" do
      socket
    else
      refresh_workspace_runtime(socket)
    end
  end

  defp refresh_after_workspace_event(socket, %Signal{
         type: "allbert.workspace.ephemeral." <> _event
       }) do
    refresh_workspace_runtime(socket)
  end

  defp refresh_after_workspace_event(socket, _signal), do: refresh_workspace(socket)

  defp handle_fragment(%Envelope{} = envelope, socket) do
    if envelope.user_id == socket.assigns.user_id and
         envelope.thread_id == socket.assigns.thread_id do
      refresh_workspace_fragment(socket, envelope)
    else
      socket
    end
  end

  defp refresh_workspace_fragment(socket, %Envelope{} = envelope) do
    cond do
      header_badge_fragment?(envelope) ->
        put_workspace_badge(socket, envelope)

      objective_card_fragment?(envelope) ->
        socket

      current_approval_fragment?(socket, envelope) ->
        socket

      true ->
        refresh_workspace_runtime(socket)
    end
  end

  defp current_approval_fragment?(socket, %Envelope{kind: kind, metadata: metadata}) do
    confirmation_id = metadata_value(metadata, :confirmation_id)

    normalize_kind(kind) == "approval_card" and
      is_binary(confirmation_id) and confirmation_id != "" and
      handoff_confirmation_id(socket.assigns.approval_handoff) == confirmation_id
  end

  defp header_badge_fragment?(%Envelope{kind: kind, metadata: metadata}) do
    normalize_kind(kind) == "badge_strip" and
      metadata_value(metadata, :placement) == "canvas_header"
  end

  defp objective_card_fragment?(%Envelope{kind: kind}) do
    normalize_kind(kind) == "objective_card"
  end

  defp handoff_confirmation_id(handoff) when is_map(handoff) do
    Map.get(handoff, :confirmation_id) || Map.get(handoff, "confirmation_id")
  end

  defp handoff_confirmation_id(_handoff), do: nil

  defp put_workspace_badge(socket, %Envelope{} = envelope) do
    badges =
      [envelope | socket.assigns.workspace_badges]
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(5)

    socket
    |> assign(:workspace_badges, badges)
    |> refresh_workspace_runtime()
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
        socket.assigns.session_id,
        socket.assigns.thread_id,
        socket.assigns.workspace_badges,
        socket.assigns.active_app,
        socket.assigns.canvas_destination,
        socket.assigns.artifacts_browser_filters
      )
    )
  rescue
    # v0.52: workspace refresh fans out several Repo reads (tiles, ephemerals,
    # conversation history). Under transient connection-pool exhaustion — e.g. a
    # long-running Task holding a checkout while a high-frequency workspace event
    # triggers a refresh — those reads can raise instead of returning {:error, _}.
    # Degrade gracefully by keeping the current assigns rather than crashing the
    # LiveView (which would disconnect the operator); the next event refreshes
    # once the pool frees up.
    exception in [DBConnection.ConnectionError] ->
      Logger.warning(
        "workspace refresh skipped: database temporarily unavailable " <>
          "thread_id=#{inspect(socket.assigns[:thread_id])} reason=#{inspect(exception.reason)}"
      )

      socket
  end

  defp refresh_after_runtime_response(socket, %{status: :needs_confirmation}) do
    socket
  end

  defp refresh_after_runtime_response(socket, response) do
    if approval_handoff_present?(Map.get(response, :approval_handoff)) do
      socket
    else
      # v0.26a M28: refresh conversation_messages + tiles + ephemerals so the
      # chat timeline accumulates completed turns without a navigation.
      refresh_workspace(socket)
    end
  end

  defp approval_handoff_present?(handoff) when is_map(handoff), do: map_size(handoff) > 0
  defp approval_handoff_present?(_handoff), do: false

  defp refresh_workspace_runtime(socket) do
    tiles = canvas_tiles(socket.assigns.thread_id, socket.assigns.user_id)
    surfaces = ephemeral_surfaces(socket.assigns.thread_id, socket.assigns.user_id)

    assign(socket,
      canvas_tiles: tiles,
      ephemeral_surfaces: surfaces,
      workspace_surface: runtime_workspace_surface(socket, tiles, surfaces)
    )
  end

  defp workspace_assigns(
         user_id,
         session_id,
         thread_id,
         workspace_badges,
         active_app,
         canvas_destination,
         artifacts_browser_filters
       ) do
    tiles = canvas_tiles(thread_id, user_id)
    surfaces = ephemeral_surfaces(thread_id, user_id)
    apps = registered_apps()

    base_context = %{
      user_id: user_id,
      thread_id: thread_id,
      session_id: session_id,
      active_app: active_app,
      canvas_destination: canvas_destination,
      artifacts_browser_filters: artifacts_browser_filters
    }

    layout = Layout.current(base_context)

    surface_context =
      registered_surface_context(base_context)

    %{
      canvas_tiles: tiles,
      ephemeral_surfaces: surfaces,
      conversation_messages: conversation_messages(thread_id, user_id),
      unified_history: unified_history(thread_id, user_id),
      recent_threads: recent_threads(user_id),
      registered_apps: apps,
      workspace_layout: layout,
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
          workspace_layout: layout,
          panel_surfaces: surface_context.panel_surfaces,
          surface_catalogs: surface_context.surface_catalogs
        )
    }
  end

  defp runtime_workspace_surface(socket, tiles, surfaces) do
    surface_context =
      registered_surface_context(%{
        user_id: socket.assigns.user_id,
        thread_id: socket.assigns.thread_id,
        session_id: socket.assigns.session_id,
        active_app: socket.assigns.active_app,
        canvas_destination: socket.assigns.canvas_destination,
        artifacts_browser_filters: socket.assigns.artifacts_browser_filters
      })

    WorkspaceCatalog.workspace_tree(
      user_id: socket.assigns.user_id,
      thread_id: socket.assigns.thread_id,
      canvas_tiles: tiles,
      ephemeral_surfaces: surfaces,
      workspace_badges: socket.assigns.workspace_badges,
      active_app: socket.assigns.active_app,
      canvas_destination: socket.assigns.canvas_destination,
      registered_apps: socket.assigns.registered_apps,
      workspace_layout: socket.assigns.workspace_layout,
      panel_surfaces: surface_context.panel_surfaces,
      surface_catalogs: surface_context.surface_catalogs
    )
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
    try do
      with {:ok, thread} <- Conversations.get_thread(user_id, thread_id) do
        Conversations.list_messages(thread, limit: 12)
      else
        _error -> []
      end
    rescue
      DBConnection.ConnectionError -> []
    end
  end

  defp unified_history(thread_id, user_id) do
    try do
      case UnifiedHistory.show_thread(user_id, thread_id, limit: 12, viewer_channel: "live_view") do
        {:ok, history} -> history
        {:error, _reason} -> nil
      end
    rescue
      DBConnection.ConnectionError -> nil
    end
  end

  defp recent_threads(user_id) do
    try do
      Conversations.list_threads(user_id, limit: 8)
    rescue
      DBConnection.ConnectionError -> []
    end
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

  defp workspace_settings_snapshot do
    identity = resolve_live_view_identity(%{}, %{})
    workspace_settings_snapshot(identity.user_id, identity.session_id)
  end

  defp workspace_settings_snapshot(user_id, session_id) do
    case Runner.run(
           "resolved_settings_snapshot",
           %{},
           workspace_read_context(user_id, session_id)
         ) do
      {:ok, %{status: :completed, settings: settings}} when is_map(settings) ->
        settings

      _other ->
        Settings.defaults()
    end
  end

  defp workspace_read_context(user_id, session_id) do
    ContextBuilder.live_view_context(
      %{user_id: user_id, session_id: session_id},
      surface: "AllbertAssistWeb.WorkspaceLive"
    )
  end

  defp workspace_theme(settings) do
    case setting(settings, "workspace.theme.mode", "system") do
      theme when theme in ["dark", "light", "system"] -> theme
      _other -> "system"
    end
  end

  defp workspace_high_contrast?(settings) do
    setting(settings, "workspace.accessibility.high_contrast", false) == true
  end

  defp workspace_reduce_motion?(settings) do
    setting(settings, "workspace.accessibility.reduce_motion", false) == true
  end

  defp workspace_offline_enabled?(settings) do
    setting(settings, "workspace.offline.enabled", true) != false
  end

  defp workspace_indexeddb_quota_bytes(settings) do
    megabytes =
      case setting(settings, "workspace.offline.indexeddb_quota_mb", 32) do
        value when is_integer(value) -> value
        _other -> 32
      end

    megabytes * 1_048_576
  end

  defp workspace_canvas_max_tiles_per_thread(settings) do
    case setting(settings, "workspace.canvas.max_tiles_per_thread", 64) do
      value when is_integer(value) -> value
      _other -> 64
    end
  end

  defp workspace_canvas_tile_body_max_bytes(settings) do
    case setting(settings, "workspace.canvas.tile_body_max_bytes", 65_536) do
      value when is_integer(value) and value > 0 -> value
      _other -> 65_536
    end
  end

  defp voice_capture_idle(settings) do
    %{
      status: :idle,
      max_bytes: voice_capture_max_bytes(settings),
      max_duration_ms: voice_capture_max_duration_ms(settings)
    }
  end

  defp voice_capture_max_bytes(settings) do
    case setting(settings, "voice.audio.max_bytes", 10_485_760) do
      value when is_integer(value) and value > 0 -> value
      _other -> 10_485_760
    end
  end

  defp voice_capture_max_duration_ms(settings) do
    case setting(settings, "voice.audio.max_duration_ms", 300_000) do
      value when is_integer(value) and value > 0 -> value
      _other -> 300_000
    end
  end

  defp image_input_idle(settings) do
    %{
      status: :idle,
      max_bytes: image_input_max_bytes(settings),
      max_pixels: image_input_max_pixels(settings),
      enabled?: setting(settings, "vision.enabled", false) == true
    }
  end

  defp image_input_max_bytes(settings) do
    case setting(settings, "vision.media.max_bytes", 20_971_520) do
      value when is_integer(value) and value > 0 -> value
      _other -> 20_971_520
    end
  end

  defp image_input_max_pixels(settings) do
    case setting(settings, "vision.media.max_pixels", 33_177_600) do
      value when is_integer(value) and value > 0 -> value
      _other -> 33_177_600
    end
  end

  defp approved_voice_capture(%{} = capture) do
    if approved_voice_capture?(capture) do
      {:ok, approved_voice_capture(capture, %{})}
    else
      {:error, :missing_voice_capture_approval}
    end
  end

  defp approved_voice_capture(_capture), do: {:error, :missing_voice_capture_approval}

  defp approved_voice_capture(output_data, confirmation) when is_map(output_data) do
    settings = workspace_settings_snapshot()
    capture_id = capture_id(output_data, confirmation)
    resource_uri = capture_resource_uri(output_data, capture_id)

    %{
      status: :approved,
      capture_id: capture_id,
      resource_uri: resource_uri,
      session_id: capture_confirmation_value(output_data, confirmation, :session_id),
      thread_id: capture_confirmation_value(output_data, confirmation, :thread_id),
      user_id: capture_confirmation_value(output_data, confirmation, :user_id),
      max_bytes:
        defaulted_capture_value(output_data, :max_bytes, voice_capture_max_bytes(settings)),
      max_duration_ms:
        defaulted_capture_value(
          output_data,
          :max_duration_ms,
          voice_capture_max_duration_ms(settings)
        ),
      retention_enabled: capture_value(output_data, :retention_enabled) == true,
      retention_root: capture_value(output_data, :retention_root),
      approved_at_ms:
        defaulted_capture_value(
          output_data,
          :approved_at_ms,
          System.monotonic_time(:millisecond)
        )
    }
  end

  defp approved_voice_capture(_output_data, _confirmation),
    do: Map.put(voice_capture_idle(workspace_settings_snapshot()), :status, :idle)

  defp approved_voice_capture?(capture) do
    capture_value(capture, :status) in [:approved, "approved"] or
      is_binary(capture_value(capture, :resource_uri))
  end

  defp capture_id(output_data, confirmation) do
    output_data
    |> capture_value(:id)
    |> default_value(capture_confirmation_value(output_data, confirmation, :capture_id))
  end

  defp capture_resource_uri(output_data, capture_id) do
    output_data
    |> capture_value(:resource_uri)
    |> default_value(mic_capture_resource_uri(capture_id))
  end

  defp mic_capture_resource_uri(capture_id) when is_binary(capture_id),
    do: ResourceURI.mic_capture!(capture_id)

  defp mic_capture_resource_uri(_capture_id), do: nil

  defp capture_confirmation_value(output_data, confirmation, key) do
    output_data
    |> capture_value(key)
    |> default_value(get_in(confirmation, ["resume_params_ref", Atom.to_string(key)]))
  end

  defp defaulted_capture_value(output_data, key, default) do
    output_data
    |> capture_value(key)
    |> default_value(default)
  end

  defp default_value(nil, default), do: default
  defp default_value(value, _default), do: value

  defp capture_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp setting(settings, key, default) do
    case Schema.get_dotted(settings, key) do
      nil -> default
      value -> value
    end
  end

  defp workspace_tile_editor_reply(params, socket) do
    with true <- socket.assigns.workspace_offline_enabled? || {:error, :offline_disabled},
         {:ok, %{status: status, result: result}}
         when status in [:completed, :conflict] <-
           run_workspace_action(
             socket,
             "record_workspace_offline_update",
             workspace_tile_editor_action_params(params, socket)
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

  defp workspace_tile_editor_action_params(params, socket) when is_map(params) do
    params
    |> Map.take([
      "tile_id",
      "snapshot",
      "update",
      "state_vector",
      "base_revision_id",
      "origin",
      "metadata"
    ])
    |> Map.merge(%{
      "thread_id" => socket.assigns.thread_id,
      "max_bytes" => socket.assigns.workspace_indexeddb_quota_bytes
    })
  end

  defp submit_voice_capture(socket) do
    with {:ok, capture} <- approved_voice_capture(socket.assigns.voice_capture),
         :ok <- validate_voice_capture_window(capture) do
      results =
        consume_uploaded_entries(socket, :voice_capture, fn %{path: path}, entry ->
          {:ok, process_voice_capture_upload(socket, path, entry, capture)}
        end)

      case results do
        [{:ok, %{transcript: transcript, voice_metadata: voice_metadata}}] ->
          socket
          |> assign(:voice_capture, voice_capture_idle(workspace_settings_snapshot()))
          |> submit_workspace_prompt(transcript, %{voice: voice_metadata})

        [{:error, reason}] ->
          assign(socket,
            error: "Voice capture failed: #{inspect(Redactor.redact(reason))}",
            voice_capture: voice_capture_idle(workspace_settings_snapshot())
          )

        [] ->
          assign(socket, :error, "Voice capture failed: no completed audio upload.")
      end
    else
      {:error, reason} ->
        assign(socket, :error, "Voice capture failed: #{inspect(Redactor.redact(reason))}")
    end
  end

  defp process_voice_capture_upload(socket, path, entry, capture) do
    with {:ok, stored} <- store_voice_capture_upload(socket, path, entry, capture) do
      transcription_path = Map.get(stored, :transcription_path, stored.path)

      result =
        case run_workspace_action(socket, "transcribe_voice", %{
               audio_file: transcription_path,
               resource_uri: capture.resource_uri
             }) do
          {:ok, %{status: :completed, transcript: transcript, voice_metadata: voice_metadata}}
          when is_binary(transcript) ->
            {:ok,
             %{
               transcript: transcript,
               voice_metadata: Redactor.redact_audio_metadata(voice_metadata)
             }}

          {:ok, %{status: status} = response} ->
            {:error, {:transcribe_voice_failed, status, Map.get(response, :error)}}
        end

      cleanup_transient_capture(stored)
      result
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_voice_capture_upload(socket, path, entry, capture) do
    with {:ok, size} <- file_size(path),
         :ok <- validate_voice_capture_size(size, capture.max_bytes),
         {:ok, name} <- voice_capture_upload_name(entry) do
      if capture.retention_enabled == true do
        store_retained_voice_capture(socket, path, entry, capture, name, size)
      else
        store_transient_voice_capture(path, capture, name, size)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp store_transient_voice_capture(path, capture, name, size) do
    with {:ok, destination} <- voice_capture_destination(capture, name),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         {:ok, _bytes} <- File.copy(path, destination) do
      {:ok,
       %{
         path: destination,
         transient?: capture.retention_enabled != true,
         byte_size: size
       }}
    end
  end

  defp store_retained_voice_capture(socket, path, entry, capture, name, size) do
    attrs = %{
      filename: name,
      content_type: Map.get(entry, :client_type),
      source_resource_uri: capture.resource_uri,
      capture_id: capture.capture_id
    }

    with {:ok, bytes} <- File.read(path),
         {:ok, destination} <- voice_capture_destination(capture, name),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         {:ok, _bytes} <- File.copy(path, destination),
         {:ok, artifact} <-
           MediaRetention.put(:voice_audio, bytes, attrs,
             context: workspace_artifact_context(socket)
           ) do
      {:ok,
       %{
         path: destination,
         artifact_path: artifact.path,
         transient?: true,
         byte_size: size,
         artifact: artifact
       }}
    end
  end

  defp voice_capture_upload_name(entry) do
    name =
      entry
      |> Map.get(:client_name, "capture.webm")
      |> to_string()
      |> Path.basename()

    extension = name |> Path.extname() |> String.downcase()

    cond do
      extension not in @voice_capture_accept ->
        {:error, {:unsupported_audio_file_type, extension}}

      name == "" ->
        {:ok, "capture#{extension}"}

      true ->
        {:ok, String.replace(name, ~r/[^A-Za-z0-9._-]/, "_")}
    end
  end

  defp voice_capture_destination(capture, name) do
    {:ok, Path.join([RuntimePaths.tmp_root(), "voice-captures", capture.capture_id, name])}
  end

  defp cleanup_transient_capture(%{transient?: true, path: path}) do
    _ = File.rm(path)
    _ = File.rmdir(Path.dirname(path))
    :ok
  end

  defp cleanup_transient_capture(_stored), do: :ok

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat.size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_voice_capture_size(size, max_bytes)
       when is_integer(size) and is_integer(max_bytes) and size <= max_bytes,
       do: :ok

  defp validate_voice_capture_size(size, max_bytes),
    do: {:error, {:audio_input_too_large, size, max_bytes}}

  defp validate_voice_capture_window(%{approved_at_ms: approved_at_ms, max_duration_ms: max})
       when is_integer(approved_at_ms) and is_integer(max) do
    elapsed_ms = System.monotonic_time(:millisecond) - approved_at_ms

    if elapsed_ms <= max + @voice_capture_duration_skew_ms do
      :ok
    else
      {:error, {:audio_input_too_long, elapsed_ms, max}}
    end
  end

  defp validate_voice_capture_window(_capture), do: {:error, :missing_voice_capture_approval}

  defp submit_workspace_prompt(socket, prompt) when is_binary(prompt) do
    prompt = String.trim(prompt)

    if prompt == "" do
      socket
    else
      do_submit_workspace_prompt(socket, prompt)
    end
  end

  defp submit_workspace_prompt(socket, _prompt), do: socket

  defp submit_workspace_prompt(socket, prompt, metadata) when is_binary(prompt) do
    prompt = String.trim(prompt)

    if prompt == "" do
      socket
    else
      do_submit_workspace_prompt(socket, prompt, metadata)
    end
  end

  defp submit_workspace_prompt(socket, _prompt, _metadata), do: socket

  defp do_submit_workspace_prompt(socket, prompt),
    do: do_submit_workspace_prompt(socket, prompt, nil)

  defp do_submit_workspace_prompt(socket, prompt, metadata) do
    with {:ok, image_inputs} <- consume_image_inputs(socket) do
      do_submit_workspace_prompt(socket, prompt, metadata, image_inputs)
    else
      {:error, reason} ->
        assign(socket, :error, "Image input failed: #{inspect(Redactor.redact(reason))}")
    end
  end

  defp do_submit_workspace_prompt(socket, prompt, metadata, image_inputs) do
    metadata = metadata |> metadata_map() |> maybe_put_image_inputs(image_inputs)

    runtime_request =
      %{
        text: prompt,
        channel: :live_view,
        user_id: socket.assigns.user_id,
        operator_id: socket.assigns.user_id,
        thread_id: socket.assigns.thread_id,
        session_id: socket.assigns.session_id,
        active_app: socket.assigns.active_app,
        canvas_destination: socket.assigns.canvas_destination
      }
      |> maybe_put_runtime_metadata(metadata)
      |> put_local_surface_ref(socket)

    event =
      EventRecorder.record_inbound(
        :live_view,
        surface_event_attrs(runtime_request, prompt, socket.assigns.user_id)
      )

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
      result = Runtime.submit_user_input(runtime_request)
      EventRecorder.mark_result(event, result)
      result
    end)
  end

  defp surface_event_attrs(request, prompt, user_id) do
    %{
      external_event_id: Map.get(request, :provider_message_id),
      user_id: user_id,
      session_id: Map.get(request, :session_id),
      thread_id: Map.get(request, :thread_id),
      payload_summary: prompt
    }
  end

  defp consume_image_inputs(socket) do
    case socket.assigns.uploads.image_input.entries do
      [] ->
        {:ok, []}

      _entries ->
        results =
          consume_uploaded_entries(socket, :image_input, fn %{path: path}, entry ->
            {:ok, process_image_input_upload(socket, path, entry)}
          end)

        case results do
          [{:ok, metadata}] -> {:ok, [metadata]}
          [{:error, reason}] -> {:error, reason}
          [] -> {:error, :no_completed_image_upload}
        end
    end
  end

  defp process_image_input_upload(socket, path, entry) do
    settings = workspace_settings_snapshot()

    with true <- setting(settings, "vision.enabled", false) == true || {:error, :vision_disabled},
         {:ok, size} <- file_size(path),
         :ok <- validate_image_input_size(size, image_input_max_bytes(settings)),
         {:ok, name} <- image_input_upload_name(entry),
         capture_id <- generated_image_capture_id(),
         {:ok, resource_uri} <- ResourceURI.image_capture(capture_id),
         {:ok, destination} <-
           image_input_destination(socket, settings, path, capture_id, resource_uri, name, entry),
         {:ok, metadata} <-
           ImageMetadata.from_path(destination,
             max_bytes: image_input_max_bytes(settings),
             resource_uri: resource_uri,
             filename: name,
             transient?: image_input_retention_enabled?(settings) != true
           ),
         {:ok, _bounds} <-
           ImageBounds.validate_input(metadata, image_input_media(settings), settings: settings) do
      {:ok, metadata}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_image_input_size(size, max_bytes)
       when is_integer(size) and is_integer(max_bytes) and size <= max_bytes,
       do: :ok

  defp validate_image_input_size(size, max_bytes),
    do: {:error, {:image_input_too_large, size, max_bytes}}

  defp image_input_upload_name(entry) do
    name =
      entry
      |> Map.get(:client_name, "image.png")
      |> to_string()
      |> Path.basename()

    extension = name |> Path.extname() |> String.downcase()

    cond do
      extension not in @image_input_accept ->
        {:error, {:unsupported_image_file_type, extension}}

      name == "" ->
        {:ok, "image#{extension}"}

      true ->
        {:ok, String.replace(name, ~r/[^A-Za-z0-9._-]/, "_")}
    end
  end

  defp image_input_destination(socket, settings, path, capture_id, resource_uri, name, entry) do
    if image_input_retention_enabled?(settings) do
      retained_image_input_destination(socket, path, capture_id, resource_uri, name, entry)
    else
      transient_image_input_destination(path, capture_id, name)
    end
  end

  defp transient_image_input_destination(path, capture_id, name) do
    destination = Path.join([RuntimePaths.tmp_root(), "image-inputs", capture_id, name])

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         {:ok, _bytes} <- File.copy(path, destination) do
      {:ok, destination}
    end
  end

  defp retained_image_input_destination(socket, path, capture_id, resource_uri, name, entry) do
    attrs = %{
      filename: name,
      content_type: Map.get(entry, :client_type),
      source_resource_uri: resource_uri,
      capture_id: capture_id
    }

    with {:ok, bytes} <- File.read(path),
         {:ok, artifact} <-
           MediaRetention.put(:vision_media, bytes, attrs,
             context: workspace_artifact_context(socket)
           ) do
      {:ok, artifact.path}
    end
  end

  defp image_input_retention_enabled?(settings),
    do: setting(settings, "vision.media.retention_enabled", false) == true

  defp image_input_media(settings) do
    %{
      "image_formats_supported" => ~w[png jpeg webp],
      "max_image_bytes" => image_input_max_bytes(settings),
      "max_image_pixels" => image_input_max_pixels(settings)
    }
  end

  defp generated_image_capture_id do
    "img_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end

  defp metadata_map(nil), do: %{}
  defp metadata_map(metadata) when is_map(metadata), do: metadata

  defp maybe_put_image_inputs(metadata, []), do: metadata

  defp maybe_put_image_inputs(metadata, image_inputs),
    do: Map.put(metadata, :image_inputs, image_inputs)

  defp maybe_put_runtime_metadata(request, metadata) when metadata in [nil, %{}], do: request
  defp maybe_put_runtime_metadata(request, metadata), do: Map.put(request, :metadata, metadata)

  defp put_local_surface_ref(request, socket) do
    case LocalSurface.thread_ref(:live_view, %{
           request_id: Ecto.UUID.generate(),
           user_id: socket.assigns.user_id,
           thread_id: socket.assigns.thread_id,
           session_id: socket.assigns.session_id
         }) do
      {:ok, ref} ->
        request
        |> Map.put(:channel_thread_ref, ref.channel_thread_ref)
        |> Map.put(:provider_message_id, ref.provider_message_id)
        |> Map.update(:metadata, ref.metadata, &Map.merge(&1, ref.metadata))

      {:error, :unknown_local_surface} ->
        request
    end
  end

  defp dismiss_intent_surface(socket, params, dismissed_by) do
    case optional_param(params, "surface-id") do
      nil ->
        socket

      surface_id ->
        case run_workspace_action(socket, "dismiss_workspace_ephemeral", %{
               surface_id: surface_id,
               dismissed_by: dismissed_by
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
    Runner.run(
      action_name,
      params,
      ContextBuilder.live_view_context(socket, surface: "AllbertAssistWeb.WorkspaceLive")
    )
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

  defp canvas_drawer_state(true), do: "open"
  defp canvas_drawer_state(false), do: "closed"

  # Map the active canvas destination to the Layout D product-sidebar nav key so the
  # operator-panel destinations (models/channels/settings/trust) highlight the right
  # sidebar item, and the plain workspace highlights "Workspace" (v0.61 M10.3 P0-8).
  defp workspace_nav_key("workspace:models"), do: "models"
  defp workspace_nav_key("workspace:channels"), do: "channels"
  defp workspace_nav_key("workspace:settings"), do: "settings"
  defp workspace_nav_key("workspace:surface_policy"), do: "trust"
  defp workspace_nav_key(_destination), do: "workspace"

  # Per-destination document title so the browser tab / screen-reader announcement
  # changes as the operator navigates workspace destinations (v0.61 M10.3 P1).
  defp workspace_page_title("workspace:models"), do: "Models"
  defp workspace_page_title("workspace:channels"), do: "Channels"
  defp workspace_page_title("workspace:settings"), do: "Settings"
  defp workspace_page_title("workspace:surface_policy"), do: "Trust"
  defp workspace_page_title(_destination), do: "Workspace"

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
  # v0.61 M9 — emit `system` so the CSS resolves it against the OS prefers-color-scheme
  # instead of falling back to light; explicit light/dark still win.
  defp theme_attribute(_system), do: "system"

  defp renderer_context(assigns) do
    %{
      user_id: assigns.user_id,
      thread_id: assigns.thread_id,
      active_objectives: assigns.active_objectives,
      conversation_messages: assigns.conversation_messages,
      unified_history: assigns.unified_history,
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
      voice_capture_upload: assigns.uploads.voice_capture,
      image_input_upload: assigns.uploads.image_input,
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
      voice_capture: assigns.voice_capture,
      image_input: assigns.image_input,
      thread_switcher_open?: assigns.thread_switcher_open?,
      workspace_overflow_open?: assigns.workspace_overflow_open?
    }
  end

  defp response_text(response) do
    SurfaceRenderer.response_text(response, %{payload: :surface_payload})
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
