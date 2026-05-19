defmodule AllbertAssistWeb.Workspace.Components.Chat do
  @moduledoc """
  Workspace fallback renderer for the existing `/agent` runtime chat loop.
  """

  use AllbertAssistWeb, :live_component

  @impl true
  def update(assigns, socket) do
    state = Map.get(assigns, :workspace_state, %{})
    context = Map.get(assigns, :renderer_context, %{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       active_objectives: Map.get(context, :active_objectives, []),
       prompt: Map.get(state, :prompt, ""),
       response: Map.get(state, :response),
       error: Map.get(state, :error),
       thread_notice: Map.get(state, :thread_notice),
       asking?: Map.get(state, :asking?, false),
       status: Map.get(state, :status),
       signal_id: Map.get(state, :signal_id),
       trace_id: Map.get(state, :trace_id),
       approval_handoff: Map.get(state, :approval_handoff),
       approval_lines: Map.get(state, :approval_lines, []),
       approval_result: Map.get(state, :approval_result),
       show_approval_details?: Map.get(state, :show_approval_details?, false)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id="workspace-chat-region"
      class="workspace-chat-pane"
      data-workspace-component={@node.component}
      aria-labelledby="workspace-chat-title"
    >
      <header class="workspace-pane-header workspace-chat-header">
        <div class="workspace-pane-title-block">
          <h2 id="workspace-chat-title" class="workspace-pane-title">Chat</h2>
          <p class="workspace-pane-subtitle">Runtime conversation</p>
        </div>
        <div :if={@active_objectives != []} id="objective-badges" class="workspace-objective-badges">
          <.link
            :for={objective <- @active_objectives}
            id={"objective-badge-#{objective.id}"}
            navigate={~p"/objectives/#{objective.id}"}
            class="allbert-chip"
          >
            <.icon name="hero-flag-micro" class="size-4" />
            <span>{objective.status}</span>
          </.link>
        </div>
      </header>

      <%= if @thread_notice do %>
        <section id="workspace-thread-notice" class="workspace-thread-notice" role="status">
          <.icon name="hero-information-circle-micro" class="size-4 shrink-0" />
          <span>{@thread_notice}</span>
        </section>
      <% end %>

      <div id="workspace-chat-timeline" class="workspace-chat-timeline" aria-live="polite">
        <article class="workspace-message workspace-message-user">
          <div class="workspace-message-avatar" aria-hidden="true">You</div>
          <div class="workspace-message-body">
            <p class="workspace-message-label">Prompt draft</p>
            <pre>{@prompt}</pre>
          </div>
        </article>

        <article :if={@response} id="agent-response" class="workspace-message workspace-message-agent">
          <div class="workspace-message-avatar" aria-hidden="true">A</div>
          <div class="workspace-message-body">
            <p class="workspace-message-label">Allbert</p>
            <pre><%= @response %></pre>
            <dl class="workspace-runtime-meta">
              <div :if={@status} id="agent-status">
                <dt>Status</dt>
                <dd>{@status}</dd>
              </div>
              <div :if={@signal_id} id="agent-signal">
                <dt>Signal</dt>
                <dd class="workspace-mono">{@signal_id}</dd>
              </div>
              <div :if={@trace_id} id="agent-trace">
                <dt>Trace</dt>
                <dd class="workspace-mono">{@trace_id}</dd>
              </div>
            </dl>
          </div>
        </article>

        <section :if={!@response} class="workspace-chat-empty">
          <span class="workspace-empty-state-icon" aria-hidden="true">
            <.icon name="hero-sparkles-mini" class="size-5" />
          </span>
          <p>
            Ask Allbert to start a runtime turn. Canvas tiles and approvals appear beside the chat.
          </p>
        </section>
      </div>

      <form
        id="agent-form"
        phx-submit="ask"
        class="workspace-composer"
        aria-busy={bool_attribute(@asking?)}
      >
        <label id="agent-prompt-label" for="agent-prompt" class="sr-only">
          Prompt for Allbert
        </label>
        <textarea
          id="agent-prompt"
          name="prompt"
          rows="3"
          class="workspace-composer-input"
          placeholder="Ask the agent something..."
          aria-labelledby="agent-prompt-label"
        ><%= @prompt %></textarea>

        <div class="workspace-composer-footer">
          <span class="workspace-composer-hint">Enter submits. Shift+Enter adds a line.</span>
          <button
            id="agent-submit"
            type="submit"
            class="workspace-button workspace-button-primary"
            disabled={@asking?}
            aria-disabled={bool_attribute(@asking?)}
          >
            <.icon name="hero-paper-airplane-micro" class="size-4" />
            {if @asking?, do: "Thinking", else: "Ask"}
          </button>
        </div>
      </form>

      <%= if @approval_handoff do %>
        <section
          id="approval-handoff"
          class="workspace-approval-inline"
          role="dialog"
          aria-modal="true"
          aria-labelledby="approval-title"
          phx-hook="FocusTrap"
        >
          <div>
            <h2 id="approval-title" class="workspace-card-title">Approval Required</h2>
            <p id="approval-confirmation" class="workspace-card-summary workspace-mono">
              Confirmation: {approval_confirmation_id(@approval_handoff)}
            </p>
          </div>

          <ul class="workspace-approval-lines">
            <li :for={line <- @approval_lines}>{line}</li>
          </ul>

          <div class="workspace-approval-actions">
            <button
              id="approval-details"
              type="button"
              phx-click="toggle_approval_details"
              class="workspace-button workspace-button-secondary"
              aria-controls="approval-details-data"
              aria-expanded={bool_attribute(@show_approval_details?)}
            >
              Details
            </button>
            <button
              id="approval-deny"
              type="button"
              phx-click="deny_confirmation"
              phx-value-id={approval_confirmation_id(@approval_handoff)}
              class="workspace-button workspace-button-danger"
            >
              Deny
            </button>
            <button
              id="approval-approve"
              type="button"
              phx-click="approve_confirmation"
              phx-value-id={approval_confirmation_id(@approval_handoff)}
              class="workspace-button workspace-button-primary"
            >
              Approve
            </button>
          </div>

          <pre
            :if={@show_approval_details?}
            id="approval-details-data"
            class="workspace-approval-details"
          ><%= inspect(@approval_handoff, pretty: true) %></pre>
        </section>
      <% end %>

      <%= if @approval_result do %>
        <section id="approval-result" class="workspace-status-callout">
          <span>{@approval_result}</span>
        </section>
      <% end %>

      <%= if @error do %>
        <section id="agent-error" class="workspace-error-callout">
          <span>{@error}</span>
        </section>
      <% end %>
    </section>
    """
  end

  defp bool_attribute(true), do: "true"
  defp bool_attribute(false), do: "false"

  defp approval_confirmation_id(handoff) when is_map(handoff) do
    Map.get(handoff, :confirmation_id) || Map.get(handoff, "confirmation_id")
  end

  defp approval_confirmation_id(_handoff), do: nil
end
