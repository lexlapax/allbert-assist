defmodule AllbertAssistWeb.AgentLive do
  @moduledoc """
  Demo LiveView for talking to the Allbert runtime boundary.

  Routes user prompts through `AllbertAssist.Runtime` asynchronously via
  `start_async/3` so the UI stays responsive.
  """
  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Runtime

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        prompt: "Hello Allbert. What can you do right now?",
        response: nil,
        error: nil,
        asking?: false,
        status: nil,
        signal_id: nil
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
        signal_id: nil
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

  @impl true
  def handle_async(:ask, {:ok, {:ok, response}}, socket) do
    {:noreply,
     assign(socket,
       asking?: false,
       response: response.message,
       status: response.status,
       signal_id: response.signal_id
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
            </div>
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
end
