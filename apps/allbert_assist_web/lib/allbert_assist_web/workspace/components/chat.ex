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
       conversation_messages: Map.get(context, :conversation_messages, []),
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
       show_approval_details?: Map.get(state, :show_approval_details?, false),
       composer_max_bytes: Map.get(context, :composer_max_bytes, 65_536)
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

      <div
        id="workspace-chat-timeline"
        class="workspace-chat-timeline"
        aria-live="polite"
        phx-hook="ChatAutoScroll"
      >
        <% latest_assistant_id = latest_assistant_message_id(@conversation_messages) %>
        <article
          :for={message <- @conversation_messages}
          id={timeline_message_dom_id(message, latest_assistant_id)}
          class={["workspace-message", message_class(message)]}
        >
          <div class="workspace-message-avatar" aria-hidden="true">
            {message_avatar(message)}
          </div>
          <div class="workspace-message-body">
            <p class="workspace-message-label">{message_label(message)}</p>
            <pre>{message_content(message)}</pre>
            <time
              :if={message_time(message)}
              class="workspace-message-time"
              datetime={message_time(message)}
            >
              {relative_time(message_time(message))}
            </time>
            <%= if message_id(message) == latest_assistant_id do %>
              <dl class="workspace-runtime-meta">
                <div :if={@status} id="agent-status">
                  <dt>Status</dt>
                  <dd>{@status}</dd>
                </div>
                <div :if={@signal_id} id="agent-signal">
                  <dt>Signal</dt>
                  <dd
                    class="workspace-mono workspace-copy-target"
                    phx-hook="CopyToClipboard"
                    id={"agent-signal-copy-#{@signal_id}"}
                    data-copy-value={@signal_id}
                    role="button"
                    tabindex="0"
                    title="Copy signal id"
                  >
                    {@signal_id}
                  </dd>
                </div>
                <div :if={@trace_id} id="agent-trace">
                  <dt>Trace</dt>
                  <dd
                    class="workspace-mono workspace-copy-target"
                    phx-hook="CopyToClipboard"
                    id={"agent-trace-copy-#{@trace_id}"}
                    data-copy-value={@trace_id}
                    role="button"
                    tabindex="0"
                    title="Copy trace id"
                  >
                    {@trace_id}
                  </dd>
                </div>
              </dl>
            <% end %>
          </div>
        </article>

        <article
          :if={show_runtime_response?(@conversation_messages, @response)}
          id="agent-response"
          class="workspace-message workspace-message-agent"
        >
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

        <section
          :if={@conversation_messages == [] and !@response}
          class="workspace-chat-empty"
        >
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
        phx-change="composer_change"
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
          placeholder="Ask Allbert anything…"
          aria-labelledby="agent-prompt-label"
          aria-describedby="agent-prompt-counter"
          phx-hook="ComposerEnter"
          data-submit-form="agent-form"
          maxlength={@composer_max_bytes}
        ><%= @prompt %></textarea>

        <div class="workspace-composer-footer">
          <span class="workspace-composer-hint">Enter submits. Shift+Enter adds a line.</span>
          <span
            id="agent-prompt-counter"
            class="workspace-composer-counter workspace-mono"
            data-near-limit={bool_attribute(composer_near_limit?(@prompt, @composer_max_bytes))}
            aria-live="polite"
          >
            {composer_counter_text(@prompt, @composer_max_bytes)}
          </span>
          <button
            id="agent-submit"
            type="submit"
            class="workspace-button workspace-button-primary"
            disabled={@asking?}
            aria-disabled={bool_attribute(@asking?)}
            phx-disable-with="Thinking"
          >
            <.icon name="hero-paper-airplane-micro" class="size-4" />
            {if @asking?, do: "Thinking", else: "Ask"}
          </button>
        </div>
      </form>

      <%= if @approval_handoff do %>
        <div
          id="approval-handoff-overlay"
          class="workspace-approval-overlay"
          data-state="open"
          aria-hidden="false"
        >
          <section
            id="approval-handoff"
            class="workspace-approval-inline workspace-approval-modal"
            role="dialog"
            aria-modal="true"
            aria-labelledby="approval-title"
            aria-describedby="approval-confirmation"
            phx-hook="FocusTrap"
            tabindex="-1"
          >
            <div>
              <p class="workspace-approval-eyebrow">Approval Required</p>
              <h2 id="approval-title" class="workspace-card-title">
                {approval_target_summary(@approval_handoff, @approval_lines)}
              </h2>
              <p
                id="approval-confirmation"
                class="workspace-card-summary workspace-mono workspace-copy-target"
                phx-hook="CopyToClipboard"
                data-copy-value={approval_confirmation_id(@approval_handoff)}
                role="button"
                tabindex="0"
                title="Copy confirmation id"
              >
                {approval_confirmation_id(@approval_handoff)}
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
                {if @show_approval_details?, do: "Hide details", else: "Details"}
              </button>
              <button
                id="approval-deny"
                type="button"
                phx-click="deny_confirmation"
                phx-value-id={approval_confirmation_id(@approval_handoff)}
                class="workspace-button workspace-button-danger"
                phx-disable-with="Denying"
              >
                Deny
              </button>
              <button
                id="approval-approve"
                type="button"
                phx-click="approve_confirmation"
                phx-value-id={approval_confirmation_id(@approval_handoff)}
                class="workspace-button workspace-button-primary"
                phx-disable-with="Approving"
              >
                Approve
              </button>
            </div>

            <pre
              :if={@show_approval_details?}
              id="approval-details-data"
              class="workspace-approval-details"
            ><%= approval_detail_text(@approval_lines) %></pre>
          </section>
        </div>
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

  defp message_id(%{id: id}) when is_binary(id), do: id
  defp message_id(_message), do: System.unique_integer([:positive])

  defp message_class(message), do: "workspace-message-#{message_role(message)}"

  defp message_avatar(message) do
    case message_role(message) do
      "assistant" -> "A"
      _role -> "You"
    end
  end

  defp message_label(message) do
    case message_role(message) do
      "assistant" -> "Allbert"
      _role -> "You"
    end
  end

  defp message_role(%{role: role}) when is_binary(role) do
    if role == "assistant", do: "assistant", else: "user"
  end

  defp message_role(_message), do: "user"

  defp message_content(%{content: content}) when is_binary(content), do: content
  defp message_content(_message), do: ""

  defp message_time(%{inserted_at: %DateTime{} = inserted_at}) do
    DateTime.to_iso8601(inserted_at)
  end

  defp message_time(_message), do: nil

  defp show_runtime_response?(_messages, response) when response in [nil, ""], do: false

  defp show_runtime_response?(messages, response) do
    !Enum.any?(messages, &(message_role(&1) == "assistant" and message_content(&1) == response))
  end

  defp latest_assistant_message_id(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(message_role(&1) == "assistant"))
    |> case do
      nil -> nil
      message -> message_id(message)
    end
  end

  defp latest_assistant_message_id(_messages), do: nil

  defp timeline_message_dom_id(message, latest_assistant_id) do
    if message_id(message) == latest_assistant_id and message_role(message) == "assistant" do
      "agent-response"
    else
      "workspace-message-#{message_id(message)}"
    end
  end

  defp relative_time(iso_string) when is_binary(iso_string) do
    with {:ok, dt, _offset} <- DateTime.from_iso8601(iso_string) do
      relative_time_string(DateTime.utc_now(), dt)
    else
      _error -> iso_string
    end
  end

  defp relative_time(_value), do: ""

  defp relative_time_string(now, then) do
    diff = DateTime.diff(now, then, :second)

    cond do
      diff < 0 -> Calendar.strftime(then, "%H:%M")
      diff < 10 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> Calendar.strftime(then, "%b %d %H:%M")
    end
  end

  defp approval_confirmation_id(handoff) when is_map(handoff) do
    Map.get(handoff, :confirmation_id) || Map.get(handoff, "confirmation_id")
  end

  defp approval_confirmation_id(_handoff), do: nil

  defp approval_detail_text(lines) when is_list(lines) do
    lines
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> case do
      [] -> "No additional approval details."
      details -> Enum.join(details, "\n")
    end
  end

  defp approval_detail_text(_lines), do: "No additional approval details."

  # v0.26a M32: derive a short human-readable target summary for the modal
  # title — operators want to see WHAT they are approving before reading the
  # full approval lines. Falls back to the first approval line, then to a
  # neutral phrase if nothing is available yet.
  defp approval_target_summary(handoff, lines) do
    Map.get(handoff || %{}, :target) ||
      Map.get(handoff || %{}, "target") ||
      first_line(lines) ||
      "Approve runtime action"
  end

  defp first_line([]), do: nil
  defp first_line([first | _rest]), do: to_string(first)
  defp first_line(_lines), do: nil

  defp composer_byte_length(prompt) when is_binary(prompt), do: byte_size(prompt)
  defp composer_byte_length(_prompt), do: 0

  defp composer_counter_text(prompt, max_bytes) when is_integer(max_bytes) do
    used = composer_byte_length(prompt)
    "#{used} / #{max_bytes}"
  end

  defp composer_counter_text(prompt, _max_bytes), do: "#{composer_byte_length(prompt)}"

  defp composer_near_limit?(prompt, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    composer_byte_length(prompt) >= div(max_bytes * 9, 10)
  end

  defp composer_near_limit?(_prompt, _max_bytes), do: false
end
