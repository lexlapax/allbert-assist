defmodule AllbertAssistWeb.AgentLive do
  @moduledoc """
  Demo LiveView for talking to `AllbertAssist.Agents.SampleAgent`.

  Starts an agent server on mount and routes user prompts through it
  asynchronously via `start_async/3` so the UI stays responsive.
  """
  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Agents.SampleAgent

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(prompt: "What is 137 * 42?", response: nil, error: nil, asking?: false)
      |> start_agent()

    {:ok, socket}
  end

  @impl true
  def handle_event("ask", %{"prompt" => prompt}, %{assigns: %{agent_pid: pid}} = socket)
      when is_pid(pid) do
    socket =
      socket
      |> assign(prompt: prompt, response: nil, error: nil, asking?: true)
      |> start_async(:ask, fn -> SampleAgent.ask_sync(pid, prompt, timeout: 30_000) end)

    {:noreply, socket}
  end

  def handle_event("ask", _params, socket) do
    {:noreply, assign(socket, error: "Agent not running. Check logs for startup errors.")}
  end

  @impl true
  def handle_async(:ask, {:ok, {:ok, result}}, socket) do
    {:noreply, assign(socket, asking?: false, response: format_result(result))}
  end

  def handle_async(:ask, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, asking?: false, error: inspect(reason))}
  end

  def handle_async(:ask, {:exit, reason}, socket) do
    {:noreply, assign(socket, asking?: false, error: "Agent crashed: #{inspect(reason)}")}
  end

  defp start_agent(socket) do
    case AllbertAssist.Jido.start_agent(SampleAgent) do
      {:ok, pid} ->
        assign(socket, agent_pid: pid)

      {:error, reason} ->
        assign(socket, agent_pid: nil, error: "Failed to start agent: #{inspect(reason)}")
    end
  end

  defp format_result(%{message: message}), do: message
  defp format_result(%{content: content}), do: content
  defp format_result(other), do: inspect(other, pretty: true)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-3xl py-10 space-y-6">
        <header>
          <h1 class="text-3xl font-bold">Sample Jido Agent</h1>
          <p class="text-base-content/70 mt-2">
            Talks to <code>AllbertAssist.Agents.SampleAgent</code>
            using the <code>:fast</code>
            model alias. Set <code>ANTHROPIC_API_KEY</code>
            (or change the alias in <code>config/config.exs</code>) before asking.
          </p>
        </header>

        <form phx-submit="ask" class="space-y-3">
          <textarea
            name="prompt"
            rows="3"
            class="textarea textarea-bordered w-full font-mono"
            placeholder="Ask the agent something..."
          ><%= @prompt %></textarea>

          <button type="submit" class="btn btn-primary" disabled={@asking?}>
            {if @asking?, do: "Thinking…", else: "Ask agent"}
          </button>
        </form>

        <%= if @response do %>
          <section class="card bg-base-200">
            <div class="card-body">
              <h2 class="card-title">Response</h2>
              <pre class="whitespace-pre-wrap text-sm"><%= @response %></pre>
            </div>
          </section>
        <% end %>

        <%= if @error do %>
          <section class="alert alert-error">
            <span>{@error}</span>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
