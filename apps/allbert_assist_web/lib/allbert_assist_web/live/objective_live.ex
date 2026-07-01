defmodule AllbertAssistWeb.ObjectiveLive do
  @moduledoc "Operator view for one durable objective."

  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Actions.ErrorExtraction
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertAssistWeb.SignalBridge
  alias AllbertAssistWeb.Workspace.Components.Patterns
  alias AllbertAssistWeb.Workspace.Components.PlanRunProgressPanel
  alias AllbertAssistWeb.Workspace.Renderer, as: WorkspaceRenderer

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
         |> assign(
           response: response_text(response),
           show_cancel?: false,
           cancel_reason: "",
           error: nil
         )
         |> refresh()}

      {:ok, response} ->
        {:noreply, assign(socket, error: response_error(response))}
    end
  end

  def handle_event("plan_build_cancel_run", %{"objective-id" => objective_id}, socket) do
    params = %{
      objective_id: objective_id,
      user_id: socket.assigns.user_id,
      reason: "Cancelled from Plan/Build run progress."
    }

    case Runner.run("cancel_plan_run", params, context(socket)) do
      {:ok, %{status: :cancelled} = response} ->
        {:noreply, socket |> assign(response: response_text(response), error: nil) |> refresh()}

      {:ok, response} ->
        {:noreply, assign(socket, error: response_error(response))}
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
        {:noreply, socket |> assign(response: response_text(response), error: nil) |> refresh()}

      {:ok, response} ->
        {:noreply, assign(socket, error: response_error(response))}
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
    <Layouts.app flash={@flash} content_width="full">
      <Layouts.operator_shell
        active="objectives"
        title={objective_title(@objective)}
        subtitle={objective_subtitle(@objective, @objective_id)}
        labelledby="objective-page-title"
      >
        <%= if @objective do %>
          <Patterns.elevated_card id="objective-header">
            <.live_component
              module={WorkspaceRenderer}
              id="objective-summary-renderer"
              surface={objective_summary_surface(@objective, @steps)}
              renderer_context={%{user_id: @user_id, page: :objectives}}
              workspace_state={%{}}
            />
          </Patterns.elevated_card>

          <section id="objective-actions" class="operator-catalog-actions">
            <.live_component
              module={WorkspaceRenderer}
              id="objective-actions-renderer"
              surface={objective_actions_surface(@objective)}
              renderer_context={%{user_id: @user_id, page: :objectives}}
              workspace_state={%{}}
            />
          </section>

          <Patterns.workspace_modal
            :if={@show_cancel?}
            id="objective-cancel-dialog"
            overlay_id="objective-cancel-modal-overlay"
            labelledby="objective-cancel-title"
            describedby="objective-cancel-help"
            dismiss_event="hide_cancel"
            click_away={true}
          >
            <form
              id="objective-cancel-modal"
              phx-submit="cancel_objective"
              class="workspace-form-stack"
            >
              <header class="workspace-pane-header">
                <div class="workspace-pane-title-block">
                  <h2 id="objective-cancel-title" class="workspace-pane-title">
                    Cancel Objective
                  </h2>
                  <p id="objective-cancel-help" class="workspace-pane-subtitle">
                    The registered cancel action records the reason and updates every open step.
                  </p>
                </div>
              </header>

              <label class="workspace-form-field">
                <span class="workspace-field-label">Reason</span>
                <textarea
                  id="objective-cancel-reason"
                  name="reason"
                  rows="3"
                  class="textarea textarea-bordered"
                  required
                ><%= @cancel_reason %></textarea>
              </label>

              <div class="workspace-pane-actions">
                <button
                  id="objective-cancel-submit"
                  type="submit"
                  class={Patterns.button_class!("danger")}
                >
                  Cancel objective
                </button>
                <button
                  type="button"
                  phx-click="hide_cancel"
                  class={Patterns.button_class!("secondary")}
                >
                  Keep running
                </button>
              </div>
            </form>
          </Patterns.workspace_modal>

          <section id="objective-acceptance" class="operator-catalog-section">
            <.live_component
              module={WorkspaceRenderer}
              id="objective-acceptance-renderer"
              surface={objective_acceptance_surface(@objective)}
              renderer_context={%{user_id: @user_id, page: :objectives}}
              workspace_state={%{}}
            />
          </section>

          <section class="operator-catalog-section" aria-labelledby="objective-steps-title">
            <h2 id="objective-steps-title" class="operator-section-title">Steps</h2>
            <div id="objective-steps">
              <.live_component
                module={WorkspaceRenderer}
                id="objective-steps-renderer"
                surface={objective_steps_surface(@steps)}
                renderer_context={%{user_id: @user_id, page: :objectives}}
                workspace_state={%{}}
              />
            </div>
          </section>

          <.live_component
            :if={workflow_objective?(@objective)}
            module={PlanRunProgressPanel}
            id="objective-plan-run-progress"
            node={plan_run_progress_node(@objective, @steps, @events)}
            renderer_context={%{user_id: @user_id, channel: :live_view}}
            workspace_state={%{}}
          />

          <section class="operator-catalog-section" aria-labelledby="objective-events-title">
            <h2 id="objective-events-title" class="operator-section-title">Events</h2>
            <div id="objective-events">
              <.live_component
                module={WorkspaceRenderer}
                id="objective-events-renderer"
                surface={objective_events_surface(@events)}
                renderer_context={%{user_id: @user_id, page: :objectives}}
                workspace_state={%{}}
              />
            </div>
          </section>
        <% else %>
          <section id="objective-missing" class="operator-catalog-section">
            <.live_component
              module={WorkspaceRenderer}
              id="objective-missing-renderer"
              surface={objective_missing_surface()}
              renderer_context={%{user_id: @user_id, page: :objectives}}
              workspace_state={%{}}
            />
          </section>
        <% end %>

        <Patterns.status_callout id="objective-response" message={@response} />
        <Patterns.error_callout id="objective-error" message={@error} />
      </Layouts.operator_shell>
    </Layouts.app>
    """
  end

  defp objective_title(nil), do: "Objective"
  defp objective_title(objective), do: objective.title

  defp objective_subtitle(nil, objective_id), do: objective_id
  defp objective_subtitle(objective, _objective_id), do: objective.id

  defp objective_summary_surface(objective, steps) do
    surface("objective-summary", [
      %Node{
        id: "objective-summary",
        component: :objective_card,
        props: %{
          dom_id: "objective-summary-card",
          title: objective.title,
          body: objective_summary_text(objective, steps),
          status: objective.status,
          objective_id: objective.id
        }
      }
    ])
  end

  defp objective_actions_surface(objective) do
    surface("objective-actions", objective_action_nodes(objective))
  end

  defp objective_action_nodes(objective) do
    [
      cancel_objective_node(objective),
      continue_objective_node(objective)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp cancel_objective_node(objective) do
    if objective.status not in ["cancelled", "completed", "failed", "abandoned"] do
      %Node{
        id: "objective-cancel",
        component: :button,
        props: %{
          dom_id: "objective-cancel-button",
          title: "Cancel",
          phx_click: "show_cancel",
          variant: "danger"
        }
      }
    end
  end

  defp continue_objective_node(%{status: "blocked"}) do
    %Node{
      id: "objective-continue",
      component: :button,
      props: %{
        dom_id: "objective-continue-button",
        title: "Continue",
        phx_click: "continue_objective",
        variant: "primary"
      }
    }
  end

  defp continue_objective_node(_objective), do: nil

  defp objective_acceptance_surface(objective) do
    nodes =
      objective[:acceptance_criteria]
      |> acceptance_lines()
      |> Enum.map(fn {label, value} ->
        %Node{
          id: "objective-acceptance-#{node_fragment(label)}",
          component: :section,
          props: %{
            title: label,
            body: value
          }
        }
      end)

    surface("objective-acceptance", nodes)
  end

  defp objective_steps_surface([]) do
    surface("objective-steps", [
      %Node{
        id: "objective-steps-empty",
        component: :empty_state,
        props: %{title: "No steps.", body: "This objective has no recorded steps yet."}
      }
    ])
  end

  defp objective_steps_surface(steps) do
    nodes =
      Enum.map(steps, fn step ->
        %Node{
          id: "objective-step-node-#{step.id}",
          component: :section,
          props: %{
            dom_id: "objective-step-#{step.id}",
            title:
              [step_status(step), step_kind(step)] |> Enum.reject(&blank?/1) |> Enum.join(" "),
            body: step_body(step),
            status: step_status(step)
          }
        }
      end)

    surface("objective-steps", nodes)
  end

  defp objective_events_surface([]) do
    surface("objective-events", [
      %Node{
        id: "objective-events-empty",
        component: :empty_state,
        props: %{title: "No events.", body: "Runtime events for this objective appear here."}
      }
    ])
  end

  defp objective_events_surface(events) do
    nodes =
      Enum.map(events, fn event ->
        %Node{
          id: "objective-event-node-#{event.id}",
          component: :section,
          props: %{
            dom_id: "objective-event-#{event.id}",
            title: event.kind,
            body: event.summary
          }
        }
      end)

    surface("objective-events", nodes)
  end

  defp objective_missing_surface do
    surface("objective-missing", [
      %Node{
        id: "objective-missing",
        component: :empty_state,
        props: %{title: "Objective not found.", body: "No local objective matched this id."}
      }
    ])
  end

  defp surface(id, nodes) do
    %Surface{
      id: id,
      app_id: :allbert,
      label: id,
      kind: :workspace,
      status: :available,
      nodes: nodes
    }
  end

  defp objective_summary_text(objective, steps) do
    [
      objective.objective,
      "User: #{objective.user_id}",
      "Active app: #{objective[:active_app] || "none"}",
      "Current step: #{current_step_text(objective, steps)}",
      "Loop count: #{objective[:loop_count] || 0}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp step_body(step) do
    [
      step[:candidate_action] || "no action",
      confirmation_text(step),
      step[:result_summary]
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp confirmation_text(%{confirmation_id: confirmation_id})
       when is_binary(confirmation_id) and confirmation_id != "" do
    "Confirmation: #{confirmation_id}"
  end

  defp confirmation_text(_step), do: nil

  defp node_fragment(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp blank?(nil), do: true

  defp blank?(value) do
    value
    |> to_string()
    |> String.trim()
    |> Kernel.==("")
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
        assign(socket, error: response_error(response))
    end
  end

  defp context(socket) do
    ContextBuilder.live_view_context(socket, surface: "AllbertAssistWeb.ObjectiveLive")
  end

  defp response_error(response), do: ErrorExtraction.from_response(response)

  defp current_step_text(objective, steps) do
    case objective[:current_step_id] || objective["current_step_id"] do
      value when is_binary(value) and value != "" ->
        value

      _missing ->
        step =
          Enum.find(steps, &(step_status(&1) in ["blocked", "running", "open"])) ||
            List.first(steps)

        step_summary(step)
    end
  end

  defp step_summary(nil), do: "none"

  defp step_summary(step) do
    [step_status(step), step_kind(step), step.id]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp step_status(step), do: Map.get(step, :status) || Map.get(step, "status")
  defp step_kind(step), do: Map.get(step, :kind) || Map.get(step, "kind")

  defp workflow_objective?(objective) do
    objective
    |> objective_value(:source_intent)
    |> case do
      "workflow:" <> _rest -> true
      _other -> false
    end
  end

  defp plan_run_progress_node(objective, steps, events) do
    %Node{
      id: "objective-plan-run-progress",
      component: :plan_run_progress_panel,
      props: %{
        objective: objective,
        steps: steps,
        events: events,
        registered_actions: ["cancel_plan_run", "list_plan_runs"]
      }
    }
  end

  defp objective_value(objective, key) when is_map(objective) do
    Map.get(objective, key) || Map.get(objective, to_string(key))
  end

  defp objective_value(_objective, _key), do: nil

  defp acceptance_lines(criteria) when is_map(criteria) and map_size(criteria) > 0 do
    criteria
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {humanize_key(key), format_value(value)} end)
  end

  defp acceptance_lines(_criteria), do: [{"Criteria", "None recorded"}]

  defp humanize_key(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
    |> then(&(&1 <> ":"))
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: Float.to_string(value)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(value) when is_list(value), do: Enum.map_join(value, ", ", &format_value/1)
  defp format_value(value) when is_map(value), do: inspect(value, pretty: false, limit: 10)
  defp format_value(nil), do: "none"
  defp format_value(value), do: to_string(value)

  defp response_text(response) do
    SurfaceRenderer.response_text(response, %{payload: :surface_payload})
  end
end
