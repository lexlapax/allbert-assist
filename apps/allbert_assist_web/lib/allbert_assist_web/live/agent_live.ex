defmodule AllbertAssistWeb.AgentLive do
  @moduledoc """
  Workspace LiveView for talking to the Allbert runtime boundary.

  Routes user prompts through `AllbertAssist.Runtime` asynchronously via
  `start_async/3` so the UI stays responsive.
  """
  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Conversations
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Runtime
  alias AllbertAssist.Session
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace
  alias AllbertAssist.Workspace.Catalog, as: WorkspaceCatalog
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssistWeb.SignalBridge
  alias AllbertAssistWeb.Workspace.Renderer, as: WorkspaceRenderer
  alias Jido.Signal

  @default_user_id "local"
  @default_session_id "web-local"

  @impl true
  def mount(params, _session, socket) do
    user_id = @default_user_id
    session_id = @default_session_id
    {thread_id, mount_error} = resolve_workspace_thread(params, user_id)
    active_app = resolve_workspace_active_app(params, user_id, session_id)

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
        workspace_theme: workspace_theme(),
        workspace_high_contrast?: workspace_high_contrast?(),
        workspace_mobile_tab: "chat",
        workspace_offline_enabled?: workspace_offline_enabled?(),
        workspace_indexeddb_quota_bytes: workspace_indexeddb_quota_bytes(),
        active_objectives: active_objectives(user_id),
        prompt: "Hello Allbert. What can you do right now?",
        response: nil,
        error: mount_error,
        asking?: false,
        status: nil,
        signal_id: nil,
        trace_id: nil,
        approval_handoff: nil,
        approval_lines: [],
        approval_result: nil,
        show_approval_details?: false,
        workspace_badges: []
      )
      |> assign(workspace_assigns(user_id, thread_id))

    {:ok, socket}
  end

  @impl true
  def handle_event("ask", %{"prompt" => prompt}, socket) do
    runtime_request = %{
      text: prompt,
      channel: :live_view,
      user_id: socket.assigns.user_id,
      operator_id: socket.assigns.user_id,
      thread_id: socket.assigns.thread_id,
      session_id: socket.assigns.session_id,
      active_app: socket.assigns.active_app
    }

    socket =
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

    {:noreply, socket}
  end

  def handle_event("toggle_approval_details", _params, socket) do
    {:noreply, update(socket, :show_approval_details?, &(!&1))}
  end

  def handle_event("toggle_workspace_theme", _params, socket) do
    next_theme = next_workspace_theme(socket.assigns.workspace_theme)

    case Settings.put("workspace.theme", next_theme, %{
           actor: socket.assigns.user_id,
           channel: :live_view
         }) do
      {:ok, _setting} ->
        {:noreply, assign(socket, :workspace_theme, next_theme)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Workspace theme update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("select_workspace_mobile_tab", %{"tab" => tab}, socket)
      when tab in ["chat", "canvas", "ephemeral"] do
    {:noreply, assign(socket, :workspace_mobile_tab, tab)}
  end

  def handle_event("select_workspace_mobile_tab", _params, socket), do: {:noreply, socket}

  def handle_event("workspace_tile_editor_sync", params, socket) do
    {:reply, workspace_tile_editor_reply(params, socket), socket}
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

  @impl true
  def handle_async(:ask, {:ok, {:ok, response}}, socket) do
    {:noreply,
     assign(socket,
       asking?: false,
       response: response.message,
       status: response.status,
       signal_id: response.signal_id,
       trace_id: Map.get(response, :trace_id),
       approval_handoff: Map.get(response, :approval_handoff),
       approval_lines: ApprovalHandoff.lines(Map.get(response, :approval_handoff))
     )}
  end

  def handle_async(:ask, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, asking?: false, error: inspect(reason))}
  end

  def handle_async(:ask, {:exit, reason}, socket) do
    {:noreply, assign(socket, asking?: false, error: "Agent crashed: #{inspect(reason)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} content_width="wide">
      <section
        id="workspace-shell"
        class={[
          "workspace-shell mx-auto max-w-6xl px-4 py-6",
          @workspace_high_contrast? && "workspace-high-contrast"
        ]}
        data-theme={theme_attribute(@workspace_theme)}
        data-workspace-theme={@workspace_theme}
        data-user-id={@user_id}
        data-thread-id={@thread_id}
        data-session-id={@session_id}
        data-active-app={active_app_attribute(@active_app)}
        data-high-contrast={bool_attribute(@workspace_high_contrast?)}
        data-mobile-tab={@workspace_mobile_tab}
        data-offline-enabled={bool_attribute(@workspace_offline_enabled?)}
        data-service-worker-url={~p"/workspace-sw.js"}
        data-service-worker-scope="/agent"
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

        <.live_component
          module={WorkspaceRenderer}
          id="agent-workspace-renderer"
          surface={@workspace_surface}
          renderer_context={renderer_context(assigns)}
          workspace_state={workspace_state(assigns)}
        />
      </section>
    </Layouts.app>
    """
  end

  defp resolve_confirmation(socket, action_name, params) do
    case Runner.run(action_name, params, approval_context(socket)) do
      {:ok, %{status: :completed, confirmation: confirmation} = response} ->
        assign(socket,
          approval_result: response.message,
          approval_handoff: update_handoff_status(socket.assigns.approval_handoff, confirmation),
          approval_lines:
            socket.assigns.approval_handoff
            |> update_handoff_status(confirmation)
            |> ApprovalHandoff.lines()
        )

      {:ok, response} ->
        assign(socket, approval_result: Map.get(response, :message, inspect(response)))
    end
  end

  defp update_handoff_status(nil, _confirmation), do: nil

  defp update_handoff_status(handoff, confirmation) do
    status = Map.get(confirmation, "status") || Map.get(confirmation, :status)
    Map.put(handoff, :status, status || Map.get(handoff, :status))
  end

  defp approval_context(socket) do
    %{
      actor: "local",
      channel: :live_view,
      surface: "AllbertAssistWeb.AgentLive",
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
    attrs = %{
      user_id: user_id,
      thread_id: param(params, "thread_id"),
      text: "Workspace session"
    }

    case Conversations.resolve_thread(attrs) do
      {:ok, thread} ->
        {thread.id, nil}

      {:error, reason} ->
        case Conversations.resolve_thread(%{user_id: user_id, text: "Workspace session"}) do
          {:ok, thread} ->
            {thread.id, "Workspace thread fallback: #{inspect(reason)}"}

          {:error, fallback_reason} ->
            raise "failed to resolve workspace thread: #{inspect(fallback_reason)}"
        end
    end
  end

  defp resolve_workspace_active_app(params, user_id, session_id) do
    requested_app = param(params, "app_id") || param(params, "active_app")

    case requested_app do
      app_id when is_binary(app_id) and app_id != "" ->
        maybe_persist_known_active_app(user_id, session_id, app_id)
        app_id

      _other ->
        session_active_app(user_id, session_id) || :allbert
    end
  end

  defp maybe_persist_known_active_app(user_id, session_id, app_id) do
    case AppRegistry.normalize_app_id(app_id) do
      {:ok, nil} ->
        _ = Session.clear_active_app(user_id, session_id)
        :ok

      {:ok, normalized} ->
        _ = Session.set_active_app(user_id, session_id, normalized)
        :ok

      {:error, :unknown_app} ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp session_active_app(user_id, session_id) do
    case Session.get(user_id, session_id, touch?: true) do
      {:ok, %{active_app: active_app}} -> active_app
      _other -> nil
    end
  end

  defp param(params, key) when is_map(params) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      _other -> nil
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
        socket.assigns.workspace_badges
      )
    )
  end

  defp workspace_assigns(user_id, thread_id, workspace_badges \\ []) do
    tiles = canvas_tiles(thread_id, user_id)
    surfaces = ephemeral_surfaces(thread_id, user_id)

    %{
      canvas_tiles: tiles,
      ephemeral_surfaces: surfaces,
      workspace_badges: workspace_badges,
      workspace_surface:
        WorkspaceCatalog.workspace_tree(
          user_id: user_id,
          thread_id: thread_id,
          canvas_tiles: tiles,
          ephemeral_surfaces: surfaces,
          workspace_badges: workspace_badges
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

  defp workspace_theme do
    case Settings.get("workspace.theme") do
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

  defp workspace_tile_editor_reply(params, socket) do
    with true <- socket.assigns.workspace_offline_enabled? || {:error, :offline_disabled},
         {:ok, result} <-
           Workspace.record_offline_update(
             Map.merge(params, %{
               "user_id" => socket.assigns.user_id,
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
    end
  end

  defp revert_tile_revision(socket, tile_id, revision_id) do
    case Runner.run(
           "revert_tile_revision",
           %{tile_id: tile_id, revision_id: revision_id, user_id: socket.assigns.user_id},
           %{actor: socket.assigns.user_id, user_id: socket.assigns.user_id, channel: :live_view}
         ) do
      {:ok, %{status: :completed}} ->
        socket

      {:ok, response} ->
        assign(socket, :error, Map.get(response, :message, inspect(response)))
    end
  end

  defp next_workspace_theme("dark"), do: "light"
  defp next_workspace_theme(_theme), do: "dark"

  defp workspace_mobile_tabs do
    [
      %{id: "chat", label: "Chat", controls: "workspace-node-workspace-chat"},
      %{id: "canvas", label: "Canvas", controls: "workspace-node-workspace-canvas-region"},
      %{
        id: "ephemeral",
        label: "Ephemeral",
        controls: "workspace-node-workspace-ephemeral-region"
      }
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
      canvas_tiles: assigns.canvas_tiles,
      ephemeral_surfaces: assigns.ephemeral_surfaces,
      workspace_badges: assigns.workspace_badges,
      workspace_theme: assigns.workspace_theme,
      workspace_high_contrast?: assigns.workspace_high_contrast?,
      workspace_offline_enabled?: assigns.workspace_offline_enabled?,
      workspace_indexeddb_quota_bytes: assigns.workspace_indexeddb_quota_bytes
    }
  end

  defp workspace_state(assigns) do
    %{
      prompt: assigns.prompt,
      response: assigns.response,
      error: assigns.error,
      asking?: assigns.asking?,
      status: assigns.status,
      signal_id: assigns.signal_id,
      trace_id: assigns.trace_id,
      approval_handoff: assigns.approval_handoff,
      approval_lines: assigns.approval_lines,
      approval_result: assigns.approval_result,
      show_approval_details?: assigns.show_approval_details?
    }
  end
end
