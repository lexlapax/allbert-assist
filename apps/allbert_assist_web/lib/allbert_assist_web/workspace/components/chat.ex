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
      class="mx-auto max-w-3xl py-4 space-y-6"
      data-workspace-component={@node.component}
      aria-labelledby="workspace-chat-title"
    >
      <header>
        <h1 id="workspace-chat-title" class="text-3xl font-bold">Allbert Runtime</h1>
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

      <form
        id="agent-form"
        phx-submit="ask"
        class="space-y-3"
        aria-busy={bool_attribute(@asking?)}
      >
        <label id="agent-prompt-label" for="agent-prompt" class="sr-only">
          Prompt for Allbert
        </label>
        <textarea
          id="agent-prompt"
          name="prompt"
          rows="3"
          class="textarea textarea-bordered w-full font-mono"
          placeholder="Ask the agent something..."
          aria-labelledby="agent-prompt-label"
        ><%= @prompt %></textarea>

        <button
          id="agent-submit"
          type="submit"
          class="btn btn-primary"
          disabled={@asking?}
          aria-disabled={bool_attribute(@asking?)}
        >
          {if @asking?, do: "Thinking…", else: "Ask Allbert"}
        </button>
      </form>

      <%= if @response do %>
        <section id="agent-response" class="card bg-base-200" aria-live="polite">
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
        <section
          id="approval-handoff"
          class="border border-base-300 bg-base-100 p-4 space-y-3"
          role="dialog"
          aria-modal="true"
          aria-labelledby="approval-title"
          phx-hook="FocusTrap"
        >
          <div>
            <h2 id="approval-title" class="font-semibold">Approval Required</h2>
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
