defmodule AllbertAssistWeb.AgentLive do
  @moduledoc """
  Demo LiveView for talking to the Allbert runtime boundary.

  Routes user prompts through `AllbertAssist.Runtime` asynchronously via
  `start_async/3` so the UI stays responsive.
  """
  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Runtime
  alias AllbertAssistWeb.SignalBridge

  @impl true
  def mount(_params, _session, socket) do
    user_id = "local"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(AllbertAssistWeb.PubSub, SignalBridge.topic_for(user_id))
      Process.send_after(self(), :refresh_objectives, 5_000)
    end

    socket =
      assign(socket,
        user_id: user_id,
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
      <div class="mx-auto max-w-3xl py-10 space-y-6">
        <header>
          <h1 class="text-3xl font-bold">Allbert Runtime</h1>
          <p class="text-base-content/70 mt-2">
            Routes prompts through <code>AllbertAssist.Runtime</code>
            using Jido signals and the primary intent agent.
          </p>
          <div :if={@active_objectives != []} id="objective-badges" class="mt-3 flex flex-wrap gap-2">
            <.link
              :for={objective <- @active_objectives}
              id={"objective-badge-#{objective.id}"}
              navigate={~p"/objectives/#{objective.id}"}
              class="badge badge-outline gap-2"
            >
              <span>{objective.status}</span>
              <span>{objective.title}</span>
            </.link>
          </div>
        </header>

        <form id="agent-form" phx-submit="ask" class="space-y-3">
          <textarea
            id="agent-prompt"
            name="prompt"
            rows="3"
            class="textarea textarea-bordered w-full font-mono"
            placeholder="Ask the agent something..."
          ><%= @prompt %></textarea>

          <button id="agent-submit" type="submit" class="btn btn-primary" disabled={@asking?}>
            {if @asking?, do: "Thinking…", else: "Ask Allbert"}
          </button>
        </form>

        <%= if @response do %>
          <section id="agent-response" class="card bg-base-200">
            <div class="card-body">
              <h2 class="card-title">Response</h2>
              <pre class="whitespace-pre-wrap text-sm"><%= @response %></pre>
              <p :if={@status} id="agent-status" class="text-xs text-base-content/60">
                Status: {@status}
              </p>
              <p :if={@signal_id} id="agent-signal" class="text-xs text-base-content/60">
                Signal: {@signal_id}
              </p>
              <p :if={@trace_id} id="agent-trace" class="text-xs text-base-content/60">
                Trace: {@trace_id}
              </p>
            </div>
          </section>
        <% end %>

        <%= if @approval_handoff do %>
          <section id="approval-handoff" class="border border-base-300 bg-base-100 p-4 space-y-3">
            <div>
              <h2 class="font-semibold">Approval Required</h2>
              <p id="approval-confirmation" class="text-xs text-base-content/60">
                Confirmation: {approval_confirmation_id(@approval_handoff)}
              </p>
            </div>

            <ul class="text-sm space-y-1">
              <li :for={line <- @approval_lines}>{line}</li>
            </ul>

            <div class="flex flex-wrap gap-2">
              <button
                id="approval-details"
                type="button"
                phx-click="toggle_approval_details"
                class="btn btn-sm"
              >
                Details
              </button>
              <button
                id="approval-deny"
                type="button"
                phx-click="deny_confirmation"
                phx-value-id={approval_confirmation_id(@approval_handoff)}
                class="btn btn-sm btn-error"
              >
                Deny
              </button>
              <button
                id="approval-approve"
                type="button"
                phx-click="approve_confirmation"
                phx-value-id={approval_confirmation_id(@approval_handoff)}
                class="btn btn-sm btn-primary"
              >
                Approve
              </button>
            </div>

            <pre
              :if={@show_approval_details?}
              id="approval-details-data"
              class="whitespace-pre-wrap text-xs bg-base-200 p-3"
            ><%= inspect(@approval_handoff, pretty: true) %></pre>
          </section>
        <% end %>

        <%= if @approval_result do %>
          <section id="approval-result" class="alert alert-info">
            <span>{@approval_result}</span>
          </section>
        <% end %>

        <%= if @error do %>
          <section id="agent-error" class="alert alert-error">
            <span>{@error}</span>
          </section>
        <% end %>
      </div>
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

  defp approval_confirmation_id(handoff) when is_map(handoff) do
    Map.get(handoff, :confirmation_id) || Map.get(handoff, "confirmation_id")
  end

  defp approval_confirmation_id(_handoff), do: nil

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
end
