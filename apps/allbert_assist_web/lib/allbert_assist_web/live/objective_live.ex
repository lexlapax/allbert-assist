defmodule AllbertAssistWeb.ObjectiveLive do
  @moduledoc "Operator view for one durable objective."

  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Actions.Runner
  alias AllbertAssistWeb.SignalBridge

  @user_id "local"

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AllbertAssistWeb.PubSub, SignalBridge.topic_for(@user_id))
      Process.send_after(self(), :refresh_objective, 5_000)
    end

    socket =
      socket
      |> assign(
        objective_id: id,
        user_id: @user_id,
        response: nil,
        objective: nil,
        steps: [],
        events: [],
        error: nil,
        cancel_reason: "",
        show_cancel?: false
      )
      |> refresh()

    {:ok, socket}
  end

  @impl true
  def handle_event("show_cancel", _params, socket) do
    {:noreply, assign(socket, show_cancel?: true, error: nil)}
  end

  def handle_event("hide_cancel", _params, socket) do
    {:noreply, assign(socket, show_cancel?: false, error: nil)}
  end

  def handle_event("cancel_objective", %{"reason" => reason}, socket) do
    params = %{id: socket.assigns.objective_id, user_id: socket.assigns.user_id, reason: reason}

    case Runner.run("cancel_objective", params, context(socket)) do
      {:ok, %{status: :cancelled} = response} ->
        {:noreply,
         socket
         |> assign(response: response.message, show_cancel?: false, cancel_reason: "", error: nil)
         |> refresh()}

      {:ok, response} ->
        {:noreply, assign(socket, error: Map.get(response, :message, inspect(response)))}
    end
  end

  def handle_event("continue_objective", _params, socket) do
    params = %{id: socket.assigns.objective_id, user_id: socket.assigns.user_id}

    case Runner.run("continue_objective", params, context(socket)) do
      {:ok, %{status: status} = response}
      when status in [
             :completed,
             :needs_confirmation,
             :still_blocked,
             :objective_abandoned,
             :objective_cancelled,
             :objective_failed
           ] ->
        {:noreply, socket |> assign(response: response.message, error: nil) |> refresh()}

      {:ok, response} ->
        {:noreply, assign(socket, error: Map.get(response, :message, inspect(response)))}
    end
  end

  @impl true
  def handle_info({:objective_event, _signal}, socket), do: {:noreply, refresh(socket)}

  def handle_info(:refresh_objective, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_objective, 5_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-4xl py-10 space-y-6">
        <.link navigate={~p"/agent"} class="text-sm link">Back to agent</.link>

        <%= if @objective do %>
          <section id="objective-header" class="space-y-3">
            <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
              <div>
                <h1 class="text-3xl font-bold">{@objective.title}</h1>
                <p class="text-sm text-base-content/60">{@objective.id}</p>
              </div>
              <span class="badge badge-lg">{@objective.status}</span>
            </div>
            <p class="whitespace-pre-wrap text-base-content/80">{@objective.objective}</p>
            <div class="grid gap-2 text-sm text-base-content/60 md:grid-cols-2">
              <p>User: {@objective.user_id}</p>
              <p>Active app: {@objective[:active_app] || "none"}</p>
              <p>Current step: {@objective[:current_step_id] || "none"}</p>
              <p>Loop count: {@objective[:loop_count] || 0}</p>
            </div>
          </section>

          <section id="objective-actions" class="flex flex-wrap gap-2">
            <button
              :if={@objective.status not in ["cancelled", "completed", "failed", "abandoned"]}
              id="objective-cancel-button"
              type="button"
              phx-click="show_cancel"
              class="btn btn-error btn-sm"
            >
              Cancel
            </button>
            <button
              :if={@objective.status == "blocked"}
              id="objective-continue-button"
              type="button"
              phx-click="continue_objective"
              class="btn btn-primary btn-sm"
            >
              Continue
            </button>
          </section>

          <form
            :if={@show_cancel?}
            id="objective-cancel-modal"
            phx-submit="cancel_objective"
            class="rounded border border-base-300 p-4 space-y-3"
          >
            <label class="form-control">
              <span class="label-text">Reason</span>
              <textarea
                id="objective-cancel-reason"
                name="reason"
                rows="3"
                class="textarea textarea-bordered"
                required
              ><%= @cancel_reason %></textarea>
            </label>
            <div class="flex gap-2">
              <button id="objective-cancel-submit" type="submit" class="btn btn-error btn-sm">
                Cancel objective
              </button>
              <button type="button" phx-click="hide_cancel" class="btn btn-ghost btn-sm">
                Keep running
              </button>
            </div>
          </form>

          <section id="objective-acceptance" class="rounded border border-base-300 p-4">
            <h2 class="font-medium">Acceptance</h2>
            <pre class="mt-2 whitespace-pre-wrap text-xs"><%= inspect(@objective[:acceptance_criteria], pretty: true) %></pre>
          </section>

          <section class="space-y-3">
            <h2 class="font-medium">Steps</h2>
            <div id="objective-steps" class="space-y-2">
              <p :if={@steps == []} class="text-sm text-base-content/60">No steps.</p>
              <div
                :for={step <- @steps}
                id={"objective-step-#{step.id}"}
                class="rounded border border-base-300 p-3 text-sm"
              >
                <div class="flex flex-wrap items-center gap-2">
                  <span class="badge">{step.status}</span>
                  <span>{step.kind}</span>
                  <span class="text-base-content/60">{step[:candidate_action] || "no action"}</span>
                </div>
                <p :if={step[:confirmation_id]} class="text-xs text-base-content/60">
                  Confirmation: {step.confirmation_id}
                </p>
                <p :if={step[:result_summary]} class="mt-2 text-sm">{step.result_summary}</p>
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <h2 class="font-medium">Events</h2>
            <div id="objective-events" class="space-y-2">
              <p :if={@events == []} class="text-sm text-base-content/60">No events.</p>
              <div
                :for={event <- @events}
                id={"objective-event-#{event.id}"}
                class="rounded border border-base-300 p-3 text-sm"
              >
                <div class="font-medium">{event.kind}</div>
                <p class="text-base-content/70">{event.summary}</p>
              </div>
            </div>
          </section>
        <% else %>
          <section id="objective-missing" class="alert alert-warning">
            <span>Objective not found.</span>
          </section>
        <% end %>

        <section :if={@response} id="objective-response" class="alert alert-info">
          <span>{@response}</span>
        </section>

        <section :if={@error} id="objective-error" class="alert alert-error">
          <span>{@error}</span>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp refresh(socket) do
    case Runner.run(
           "show_objective",
           %{id: socket.assigns.objective_id, user_id: socket.assigns.user_id},
           context(socket)
         ) do
      {:ok, %{status: :completed} = response} ->
        assign(socket,
          objective: response.objective,
          steps: response.steps,
          events: response.events,
          error: nil
        )

      {:ok, %{status: :not_found}} ->
        assign(socket, objective: nil, steps: [], events: [], error: nil)

      {:ok, response} ->
        assign(socket, error: Map.get(response, :message, inspect(response)))
    end
  end

  defp context(socket) do
    %{
      actor: socket.assigns.user_id,
      user_id: socket.assigns.user_id,
      operator_id: socket.assigns.user_id,
      channel: :live_view,
      surface: "AllbertAssistWeb.ObjectiveLive",
      response_target: socket.id
    }
  end
end
