defmodule AllbertAssistWeb.Workspace.Components.PlanPreviewPanel do
  @moduledoc "Workspace renderer for Plan/Build preview packets."

  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertAssistWeb.Workspace.Components.Base
  alias AllbertAssistWeb.Workspace.Components.Patterns

  @impl true
  def update(assigns, socket) do
    node = Map.fetch!(assigns, :node)
    props = node.props || %{}

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:preview, prop(props, :preview, %{}))
     |> assign(:workflow_id, prop(props, :workflow_id))
     |> assign(:inputs, prop(props, :inputs, %{}))
     |> assign(:registered_actions, prop(props, :registered_actions, []))
     |> assign_new(:expanded_editor?, fn -> false end)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("plan_build_toggle_editor", _params, socket) do
    {:noreply, update(socket, :expanded_editor?, &(!&1))}
  end

  def handle_event("plan_build_save_preview", params, socket) do
    inputs = Map.get(params, "inputs", %{})
    edits = Map.get(params, "edits", %{})

    workflow_id =
      socket.assigns.workflow_id || preview_value(socket.assigns.preview, :workflow_id)

    case Runner.run(
           "preview_plan",
           %{workflow_id: workflow_id, inputs: inputs, edits: edits},
           panel_context(socket)
         ) do
      {:ok, %{status: :advisory, output_data: %{preview: preview}}} ->
        {:noreply, assign(socket, preview: preview, inputs: inputs, error: nil)}

      {:ok, response} ->
        {:noreply, assign(socket, error: Map.get(response, :message, inspect(response)))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <article
      id={"workspace-component-#{@node.id}"}
      class="workspace-card"
      data-workspace-component="plan_preview_panel"
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <header class="workspace-card-header">
        <span class="workspace-card-icon" aria-hidden="true">
          <.icon name="hero-clipboard-document-list-micro" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <h2 id={Base.component_title_id(@node)} class="workspace-card-title">
            {preview_title(@preview, @node)}
          </h2>
          <p class="workspace-card-summary">
            {preview_summary(@preview)}
          </p>
        </div>
        <span class="workspace-status-pill workspace-status-info">
          {preview_value(@preview, :step_count) || 0} steps
        </span>
      </header>

      <section class="mt-3 grid gap-2 text-sm md:grid-cols-2" data-plan-preview-meta>
        <p>
          <span class="font-medium">Workflow</span> {preview_value(@preview, :workflow_id) || "none"}
        </p>
        <p>
          <span class="font-medium">Version</span> {preview_value(@preview, :workflow_version) ||
            "none"}
        </p>
        <p>
          <span class="font-medium">Inputs</span> {inspect_value(
            preview_value(@preview, :resolved_inputs) || @inputs
          )}
        </p>
        <p>
          <span class="font-medium">Warnings</span> {length(
            List.wrap(preview_value(@preview, :warnings))
          )}
        </p>
      </section>

      <div class="mt-3 flex flex-wrap gap-2">
        <button
          type="button"
          class={Patterns.compact_button_class!("secondary")}
          phx-click="plan_build_toggle_editor"
          phx-target={@myself}
        >
          Open editor
        </button>
        <button
          type="button"
          class={Patterns.compact_button_class!("primary")}
          phx-click="plan_build_start_run"
          phx-value-workflow-id={preview_value(@preview, :workflow_id)}
        >
          Start run
        </button>
      </div>

      <section
        :if={@expanded_editor?}
        id={"plan-preview-editor-modal-#{@node.id}"}
        class="fixed inset-4 z-50 overflow-auto rounded border border-base-300 bg-base-100 p-4 shadow-2xl md:inset-10"
        data-plan-preview-editor-modal
      >
        <header class="mb-3 flex items-center justify-between gap-3">
          <h3 class="text-base font-semibold">Plan editor</h3>
          <button
            type="button"
            class={Patterns.compact_button_class!("secondary")}
            phx-click="plan_build_toggle_editor"
            phx-target={@myself}
          >
            Close
          </button>
        </header>

        <form
          id={"plan-preview-editor-#{@node.id}"}
          class="rounded border border-base-300 p-3"
          phx-submit="plan_build_save_preview"
          phx-target={@myself}
        >
          <div class="grid gap-2 md:grid-cols-2">
            <label :for={{key, value} <- input_rows(@inputs, @preview)} class="form-control">
              <span class="label-text">{key}</span>
              <input class="input input-bordered input-sm" name={"inputs[#{key}]"} value={value} />
            </label>
          </div>
          <div class="mt-4 space-y-2" data-plan-preview-step-editor>
            <div
              :for={step <- preview_steps(@preview)}
              class="grid gap-2 rounded border border-base-300 p-2 text-sm md:grid-cols-[minmax(0,1fr)_7rem_7rem_7rem]"
              data-plan-preview-step-editor-row={step_value(step, :id)}
            >
              <div class="min-w-0">
                <p class="font-medium">{step_label(step)}</p>
                <p class="truncate text-base-content/70">
                  {step_value(step, :action_name) || step_value(step, :kind)}
                </p>
              </div>
              <label class="label cursor-pointer justify-start gap-2">
                <input
                  type="hidden"
                  name={"edits[steps][#{step_value(step, :id)}][enabled]"}
                  value="false"
                />
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  name={"edits[steps][#{step_value(step, :id)}][enabled]"}
                  value="true"
                  checked
                />
                <span class="label-text">Keep</span>
              </label>
              <label class="label cursor-pointer justify-start gap-2">
                <input
                  type="hidden"
                  name={"edits[steps][#{step_value(step, :id)}][confirm]"}
                  value="false"
                />
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  name={"edits[steps][#{step_value(step, :id)}][confirm]"}
                  value="true"
                  checked={step_value(step, :confirmations_required) == true}
                />
                <span class="label-text">Confirm</span>
              </label>
              <label class="form-control">
                <span class="label-text">Order</span>
                <input
                  class="input input-bordered input-sm"
                  name={"edits[steps][#{step_value(step, :id)}][order]"}
                  value={step_value(step, :ordinal)}
                />
              </label>
            </div>
          </div>
          <div class="mt-3 flex flex-wrap gap-2">
            <button type="submit" class={Patterns.compact_button_class!("secondary")}>
              Recompute preview
            </button>
          </div>
        </form>
      </section>

      <p :if={@error} class="mt-3 alert alert-error text-sm">{@error}</p>

      <section class="mt-4 space-y-3" data-plan-preview-steps>
        <article
          :for={step <- preview_steps(@preview)}
          id={"plan-preview-step-#{step_value(step, :ordinal)}"}
          class="rounded border border-base-300 p-3 text-sm"
          data-plan-preview-step={step_value(step, :id)}
        >
          <div class="mb-2 flex flex-wrap items-center gap-2">
            <span class="badge">{step_value(step, :ordinal)}</span>
            <span class="font-medium">{step_value(step, :kind)}</span>
            <span>{step_value(step, :action_name) || "no action"}</span>
            <span class="workspace-status-pill workspace-status-neutral">
              {step_value(step, :confidence_tier) || "unknown"}
            </span>
          </div>
          <dl class="grid gap-1 md:grid-cols-2">
            <div :for={{label, value} <- step_fields(step)} class="min-w-0">
              <dt class="font-medium text-base-content/70">{label}</dt>
              <dd class="break-words">{value}</dd>
            </div>
          </dl>
        </article>
      </section>

      <section class="mt-4" data-plan-preview-authority>
        <h3 class="text-sm font-medium">Authority gates</h3>
        <ul class="mt-2 space-y-1 text-sm">
          <li :for={gate <- List.wrap(preview_value(@preview, :authority_gates))}>
            {inspect_value(gate)}
          </li>
          <li :if={List.wrap(preview_value(@preview, :authority_gates)) == []}>none</li>
        </ul>
      </section>

      <footer class="workspace-card-footer">
        <span>Actions: {Enum.join(@registered_actions, ", ")}</span>
      </footer>
    </article>
    """
  end

  defp panel_context(socket) do
    socket.assigns
    |> Map.get(:renderer_context, %{})
    |> ContextBuilder.live_view_context(surface: "/workspace")
  end

  defp preview_title(preview, node) do
    preview_value(preview, :objective_title) || Base.title(node, "Plan/Build Preview")
  end

  defp preview_summary(preview) do
    case preview_value(preview, :workflow_id) do
      nil -> "No plan preview loaded."
      workflow_id -> "Workflow #{workflow_id} is ready for operator review."
    end
  end

  defp input_rows(inputs, preview) do
    resolved = preview_value(preview, :resolved_inputs) || %{}
    source = if map_size(Map.new(inputs || %{})) > 0, do: inputs, else: resolved

    source
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp preview_steps(preview), do: List.wrap(preview_value(preview, :steps))

  defp step_label(step) do
    [step_value(step, :ordinal), step_value(step, :id)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(". ")
  end

  defp step_fields(step) do
    [
      {"Params", inspect_value(step_value(step, :params_summary))},
      {"Permission", inspect_value(step_value(step, :permission))},
      {"Safety floor", inspect_value(step_value(step, :safety_floor))},
      {"Resources", inspect_value(step_value(step, :resources_needed))},
      {"Estimated cost", inspect_value(step_value(step, :estimated_cost))},
      {"Confirmations required", inspect_value(step_value(step, :confirmations_required))},
      {"Subagent target", inspect_value(step_value(step, :subagent_target))},
      {"Failure blast radius", inspect_value(step_value(step, :failure_blast_radius))}
    ]
  end

  defp preview_value(preview, key) when is_map(preview),
    do: Map.get(preview, key) || Map.get(preview, to_string(key))

  defp preview_value(_preview, _key), do: nil
  defp step_value(step, key), do: preview_value(step, key)

  defp prop(map, key), do: prop(map, key, nil)

  defp prop(map, key, fallback) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key), fallback)

  defp prop(_map, _key, fallback), do: fallback

  defp inspect_value(nil), do: "none"
  defp inspect_value(value) when is_binary(value), do: value
  defp inspect_value(value) when is_atom(value), do: Atom.to_string(value)
  defp inspect_value(value), do: inspect(value, pretty: false, limit: 20)
end

defmodule AllbertAssistWeb.Workspace.Components.PlanRunProgressPanel do
  @moduledoc "Workspace renderer for Plan/Build run progress."

  use AllbertAssistWeb, :live_component

  alias AllbertAssistWeb.Workspace.Components.Base
  alias AllbertAssistWeb.Workspace.Components.Patterns

  @impl true
  def update(assigns, socket) do
    node = Map.fetch!(assigns, :node)
    props = node.props || %{}

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:objective, prop(props, :objective, %{}))
     |> assign(:steps, List.wrap(prop(props, :steps, [])))
     |> assign(:events, List.wrap(prop(props, :events, [])))
     |> assign(:registered_actions, prop(props, :registered_actions, []))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <article
      id={"workspace-component-#{@node.id}"}
      class="workspace-card"
      data-workspace-component="plan_run_progress_panel"
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <header class="workspace-card-header">
        <span class="workspace-card-icon" aria-hidden="true">
          <.icon name="hero-list-bullet-micro" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <h2 id={Base.component_title_id(@node)} class="workspace-card-title">
            {objective_value(@objective, :title) || "Run Progress"}
          </h2>
          <p class="workspace-card-summary">
            {objective_value(@objective, :source_intent) || "No workflow run selected."}
          </p>
        </div>
        <span class="workspace-status-pill workspace-status-info">
          {objective_value(@objective, :status) || "unknown"}
        </span>
      </header>

      <div class="mt-3 flex flex-wrap gap-2">
        <button
          type="button"
          class={Patterns.compact_button_class!("danger")}
          phx-click="plan_build_cancel_run"
          phx-value-objective-id={objective_value(@objective, :id)}
        >
          Cancel plan
        </button>
      </div>

      <section class="mt-4 space-y-3" data-plan-run-steps>
        <article
          :for={step <- @steps}
          id={"plan-run-step-#{step_value(step, :id)}"}
          class="rounded border border-base-300 p-3 text-sm"
          data-plan-run-step={step_value(step, :id)}
        >
          <div class="flex flex-wrap items-center gap-2">
            <span class="badge">{step_value(step, :status) || "proposed"}</span>
            <span class="font-medium">{step_value(step, :kind)}</span>
            <span>{step_value(step, :candidate_action) || "no action"}</span>
            <span
              :if={step_value(step, :delegate_agent_id)}
              class="workspace-status-pill workspace-status-neutral"
            >
              {step_value(step, :delegate_agent_id)}
            </span>
          </div>
          <p :if={step_value(step, :result_summary)} class="mt-2">
            {step_value(step, :result_summary)}
          </p>
          <div class="mt-3 space-y-1" data-plan-run-step-events>
            <p
              :for={event <- step_events(@events, step)}
              class="rounded bg-base-200 px-2 py-1 text-xs"
              data-plan-run-event={event_value(event, :kind)}
            >
              {event_value(event, :kind)} · {event_value(event, :summary)}
            </p>
          </div>
          <div
            :if={delegate_step?(step)}
            class="mt-3 border-l-2 border-base-300 pl-3"
            data-plan-subagent-events
          >
            <p class="text-xs font-medium text-base-content/70">Subagent events</p>
            <p
              :for={event <- child_events(@events, step)}
              class="mt-1 rounded bg-base-200 px-2 py-1 text-xs"
            >
              {event_value(event, :kind)} · {event_value(event, :summary)}
            </p>
            <p :if={child_events(@events, step) == []} class="mt-1 text-xs text-base-content/60">
              No child events.
            </p>
          </div>
        </article>
        <p :if={@steps == []} class="text-sm text-base-content/60">No plan steps yet.</p>
      </section>

      <footer class="workspace-card-footer">
        <span>Events: {length(@events)}</span>
        <span>Actions: {Enum.join(@registered_actions, ", ")}</span>
      </footer>
    </article>
    """
  end

  defp step_events(events, step) do
    step_id = step_value(step, :id)

    Enum.filter(
      events,
      &(event_value(&1, :step_id) == step_id and child_parent_id(&1) in [nil, ""])
    )
  end

  defp child_events(events, step) do
    step_id = step_value(step, :id)
    Enum.filter(events, &(child_parent_id(&1) == step_id))
  end

  defp child_parent_id(event) do
    payload = event_value(event, :payload)
    prop(payload, :parent_step_id, nil) || prop(payload, :parent_id, nil)
  end

  defp delegate_step?(step), do: step_value(step, :kind) in ["delegate_agent", :delegate_agent]

  defp objective_value(objective, key), do: value(objective, key)
  defp step_value(step, key), do: value(step, key)
  defp event_value(event, key), do: value(event, key)

  defp value(map, key) when is_map(map), do: AllbertAssist.Maps.field_truthy(map, key)
  defp value(_map, _key), do: nil

  defp prop(map, key, fallback) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key), fallback)

  defp prop(_map, _key, fallback), do: fallback
end
