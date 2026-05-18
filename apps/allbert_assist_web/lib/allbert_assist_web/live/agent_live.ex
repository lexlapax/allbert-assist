defmodule AllbertAssistWeb.AgentLive do
  @moduledoc """
  Workspace LiveView for talking to the Allbert runtime boundary.

  Routes user prompts through `AllbertAssist.Runtime` asynchronously via
  `start_async/3` so the UI stays responsive.
  """
  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Runtime
  alias AllbertAssist.Workspace
  alias AllbertAssist.Workspace.Catalog, as: WorkspaceCatalog
  alias AllbertAssistWeb.SignalBridge
  alias AllbertAssistWeb.Workspace.Renderer, as: WorkspaceRenderer

  @impl true
  def mount(_params, _session, socket) do
    user_id = "local"
    thread_id = "local-default"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(AllbertAssistWeb.PubSub, SignalBridge.topic_for(user_id))
      Process.send_after(self(), :refresh_objectives, 5_000)
    end

    socket =
      assign(socket,
        user_id: user_id,
        thread_id: thread_id,
        workspace_surface:
          WorkspaceCatalog.workspace_tree(user_id: user_id, thread_id: thread_id),
        canvas_tiles: canvas_tiles(thread_id, user_id),
        ephemeral_surfaces: ephemeral_surfaces(thread_id, user_id),
        active_objectives: active_objectives(user_id),
        prompt: "Hello Allbert. What can you do right now?",
        response: nil,
        error: nil,
        asking?: false,
        status: nil,
        signal_id: nil,
        trace_id: nil,
        approval_handoff: nil,
        approval_lines: [],
        approval_result: nil,
        show_approval_details?: false
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("ask", %{"prompt" => prompt}, socket) do
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
        Runtime.submit_user_input(%{
          text: prompt,
          channel: :live_view,
          operator_id: "local"
        })
      end)

    {:noreply, socket}
  end

  def handle_event("toggle_approval_details", _params, socket) do
    {:noreply, update(socket, :show_approval_details?, &(!&1))}
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
    <Layouts.app flash={@flash}>
      <section id="workspace-shell" class="mx-auto max-w-6xl px-4 py-6">
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

  defp renderer_context(assigns) do
    %{
      user_id: assigns.user_id,
      thread_id: assigns.thread_id,
      active_objectives: assigns.active_objectives,
      canvas_tiles: assigns.canvas_tiles,
      ephemeral_surfaces: assigns.ephemeral_surfaces
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
