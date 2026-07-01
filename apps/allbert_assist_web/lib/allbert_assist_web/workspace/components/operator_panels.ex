# credo:disable-for-this-file Credo.Check.Readability.ModuleDoc
defmodule AllbertAssistWeb.Workspace.Components.OperatorPanels do
  @moduledoc false

  alias AllbertAssist.Maps
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertAssistWeb.Workspace.Components.Patterns

  @spec action_context(map()) :: map()
  def action_context(assigns) when is_map(assigns) do
    renderer_context = Map.get(assigns, :renderer_context, %{}) || %{}

    renderer_context
    |> ContextBuilder.live_view_context(surface: "/workspace")
    |> Map.merge(Map.take(renderer_context, [:audit?, :req_options]))
  end

  @spec open?(map(), String.t()) :: boolean()
  def open?(assigns, destination) when is_map(assigns) do
    renderer_context = Map.get(assigns, :renderer_context, %{}) || %{}
    node = Map.get(assigns, :node)

    field(renderer_context, :canvas_destination) == destination or
      field(node_props(node), :force_load?) == true
  end

  def node_props(%{props: props}) when is_map(props), do: props
  def node_props(_node), do: %{}

  def field(map, key, default \\ nil), do: Maps.field(map, key, default)

  def safe_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  def count(value) when is_list(value), do: length(value)
  def count(value) when is_integer(value), do: value
  def count(_value), do: 0

  def summary_count(summary, key) when is_map(summary), do: Map.get(summary, key, 0)
  def summary_count(_summary, _key), do: 0

  def list_label(values) when is_list(values) and values != [], do: Enum.join(values, ", ")
  def list_label(_values), do: "none"

  def status_label(nil), do: "unknown"
  def status_label(value) when is_atom(value), do: value |> Atom.to_string() |> status_label()

  def status_label(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.replace("-", " ")
  end

  def status_class(value) when value in [:pass, :ok, "pass", "ok", "completed"],
    do: "workspace-status-ok"

  def status_class(value)
      when value in [:fail, :rejected, :denied, "fail", "rejected", "denied"],
      do: "workspace-status-error"

  def status_class(value)
      when value in ["missing", "under-capable", "not-pulled", "remote-egress-warning"],
      do: "workspace-status-warn"

  def status_class(_value), do: "workspace-status-neutral"

  def button_class!(variant), do: Patterns.compact_button_class!(variant)
end

defmodule AllbertAssistWeb.Workspace.Components.IntentsPanel do
  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.Actions.Runner
  alias AllbertAssistWeb.Workspace.Components.OperatorPanels, as: Support

  @destination "workspace:intents"
  @write_actions %{
    "edit" => "edit_intent_descriptor",
    "disable" => "disable_intent_descriptor",
    "enable" => "enable_intent_descriptor",
    "promote" => "promote_intent_descriptor"
  }

  @impl true
  def update(assigns, socket) do
    loaded? = Map.get(socket.assigns, :intents_loaded?, false)

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:node, fn -> nil end)
      |> assign_new(:renderer_context, fn -> %{} end)
      |> assign_new(:intents_loaded?, fn -> false end)
      |> assign_new(:intents_notice, fn -> "" end)
      |> assign_new(:intents_diagnostics, fn -> "" end)
      |> assign_new(:intent_coverage, fn -> %{} end)
      |> assign_new(:intent_eval, fn -> nil end)
      |> assign_new(:intent_descriptors, fn -> [] end)
      |> assign_new(:intent_review, fn -> [] end)

    open? = Support.open?(socket.assigns, @destination)
    socket = assign(socket, :intents_panel_open?, open?)

    if open? and not loaded? do
      {:ok, refresh(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("refresh_intents", _params, socket) do
    {:noreply, refresh(socket, include_eval?: true)}
  end

  def handle_event(
        "intent_operator_action",
        %{"operator-action" => operator_action, "action" => action_name},
        socket
      ) do
    case Map.fetch(@write_actions, operator_action) do
      {:ok, runner_action} ->
        context = Support.action_context(socket.assigns)
        {:ok, response} = Runner.run(runner_action, %{action: action_name}, context)

        socket =
          refresh(socket)
          |> assign(
            :intents_notice,
            Support.field(response, :message, "Intent action completed.")
          )
          |> assign(:intents_diagnostics, diagnostics(response))

        {:noreply, socket}

      :error ->
        {:noreply,
         assign(socket,
           intents_notice: "",
           intents_diagnostics: "Unsupported intent operator action: #{operator_action}"
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <article
      id="workspace-intents-panel"
      class="workspace-settings-panel workspace-operator-panel"
      data-workspace-component="intents_panel"
      data-workspace-renderer="component"
      data-action-source="actions-runner"
      aria-labelledby="workspace-intents-panel-title"
    >
      <header class="workspace-settings-panel-header">
        <span class="workspace-card-icon" aria-hidden="true">
          <.icon name="hero-bolt-micro" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <h2 id="workspace-intents-panel-title" class="workspace-card-title">Intents</h2>
          <p class="workspace-card-summary">
            Descriptor coverage, eval gate posture, and reviewed mutations.
          </p>
        </div>
        <button
          type="button"
          id="workspace-intents-refresh"
          class={Support.button_class!("secondary")}
          phx-click="refresh_intents"
          phx-target={@myself}
        >
          Refresh
        </button>
      </header>

      <div :if={!@intents_panel_open?} class="workspace-settings-panel-preview">
        Open the Intents workspace tool to load action-backed operator DTOs.
      </div>

      <div :if={@intents_panel_open?} class="workspace-settings-panel-body">
        <p :if={@intents_notice != ""} id="workspace-intents-notice" class="text-sm">
          {@intents_notice}
        </p>
        <p :if={@intents_diagnostics != ""} id="workspace-intents-diagnostics" class="text-sm">
          {@intents_diagnostics}
        </p>

        <section id="workspace-intents-coverage" class="workspace-operator-panel-section">
          <h3 class="workspace-rail-title">Coverage</h3>
          <div class="workspace-operator-metrics">
            <span>Routable {Support.count(Support.field(@intent_coverage, :routable))}</span>
            <span>
              Agent actions {Support.count(Support.field(@intent_coverage, :agent_exposed))}
            </span>
            <span>Missing {Support.count(Support.field(@intent_coverage, :missing))}</span>
            <span>Review {Support.count(Support.field(@intent_coverage, :review_pending))}</span>
            <span>Overrides {Support.count(Support.field(@intent_coverage, :overridden))}</span>
            <span>Disabled {Support.count(Support.field(@intent_coverage, :disabled))}</span>
          </div>
        </section>

        <section id="workspace-intents-eval" class="workspace-operator-panel-section">
          <h3 class="workspace-rail-title">Eval Gate</h3>
          <div class="workspace-operator-metrics">
            <span class={["workspace-status-pill", Support.status_class(gate_status(@intent_eval))]}>
              {Support.status_label(gate_status(@intent_eval))}
            </span>
            <span>Total {Support.count(score_field(@intent_eval, :total))}</span>
            <span>Passed {Support.count(score_field(@intent_eval, :passed))}</span>
            <span>Accuracy {score_field(@intent_eval, :overall_accuracy, "n/a")}</span>
            <span>Baseline {baseline_id(@intent_eval)}</span>
          </div>
        </section>

        <section id="workspace-intents-review" class="workspace-operator-panel-section">
          <h3 class="workspace-rail-title">Review Queue</h3>
          <p :if={@intent_review == []} class="text-sm">No descriptors pending review.</p>
          <div
            :for={proposal <- Enum.take(@intent_review, 8)}
            id={"workspace-intent-review-#{Support.safe_id(proposal.action_name)}"}
            class="workspace-operator-row"
          >
            <div class="min-w-0">
              <div class="font-medium">{proposal.action_name}</div>
              <div class="text-xs">
                {proposal.app_id} support={proposal.support_count} evidence={proposal.evidence_count}
              </div>
            </div>
            <button
              type="button"
              id={"workspace-intent-promote-#{Support.safe_id(proposal.action_name)}"}
              class={Support.button_class!("primary")}
              phx-click="intent_operator_action"
              phx-target={@myself}
              phx-value-operator-action="promote"
              phx-value-action={proposal.action_name}
            >
              Promote
            </button>
          </div>
        </section>

        <section id="workspace-intents-descriptors" class="workspace-operator-panel-section">
          <h3 class="workspace-rail-title">Descriptors</h3>
          <div
            :for={descriptor <- Enum.take(@intent_descriptors, 12)}
            id={"workspace-intent-descriptor-#{Support.safe_id(descriptor.action_name)}"}
            class="workspace-operator-row"
          >
            <div class="min-w-0">
              <div class="font-medium">{descriptor.action_name}</div>
              <div class="text-xs">
                {descriptor.source_label} app={descriptor.app_id} examples={descriptor.examples_count} slots={Support.list_label(
                  descriptor.required_slots
                )}
              </div>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                type="button"
                id={"workspace-intent-edit-#{Support.safe_id(descriptor.action_name)}"}
                class={Support.button_class!("secondary")}
                phx-click="intent_operator_action"
                phx-target={@myself}
                phx-value-operator-action="edit"
                phx-value-action={descriptor.action_name}
              >
                Edit
              </button>
              <button
                type="button"
                id={"workspace-intent-toggle-#{Support.safe_id(descriptor.action_name)}"}
                class={Support.button_class!("secondary")}
                phx-click="intent_operator_action"
                phx-target={@myself}
                phx-value-operator-action={if descriptor.disabled?, do: "enable", else: "disable"}
                phx-value-action={descriptor.action_name}
              >
                {if descriptor.disabled?, do: "Enable", else: "Disable"}
              </button>
            </div>
          </div>
        </section>
      </div>
    </article>
    """
  end

  defp refresh(socket, opts \\ []) do
    context = Support.action_context(socket.assigns)
    include_eval? = Keyword.get(opts, :include_eval?, false)

    with {:ok, coverage} <-
           ActionHelper.completed_action("intent_coverage", operator_report_params(), context),
         {:ok, descriptors} <-
           ActionHelper.completed_action(
             "intent_list_descriptors",
             operator_report_params(),
             context
           ),
         {:ok, review} <-
           ActionHelper.completed_action("intent_list_review", operator_report_params(), context) do
      socket =
        assign(socket,
          intents_loaded?: true,
          intents_diagnostics: "",
          intent_coverage: coverage.coverage,
          intent_descriptors: descriptors.descriptors,
          intent_review: review.proposals
        )

      if include_eval? do
        refresh_eval(socket, context)
      else
        socket
      end
    else
      {:error, reason} ->
        assign(socket,
          intents_loaded?: true,
          intents_diagnostics: inspect(reason)
        )
    end
  end

  defp refresh_eval(socket, context) do
    case ActionHelper.completed_action("intent_eval_run", %{}, context) do
      {:ok, eval} ->
        assign(socket,
          intents_diagnostics: "",
          intent_eval: eval.eval_result
        )

      {:error, reason} ->
        assign(socket, intents_diagnostics: inspect(reason))
    end
  end

  defp diagnostics(response) do
    case Support.field(response, :status) do
      :completed -> ""
      "completed" -> ""
      status -> "Intent action status: #{Support.status_label(status)}"
    end
  end

  defp operator_report_params do
    %{render_mode: "operator_report", surface_policy_affordance: true}
  end

  defp gate_status(nil), do: "deferred"
  defp gate_status(eval), do: eval |> Support.field(:gate, %{}) |> Support.field(:status)

  defp baseline_id(nil), do: "not run"
  defp baseline_id(eval), do: eval |> Support.field(:baseline, %{}) |> Support.field(:id, "none")

  defp score_field(eval, key, default \\ 0) do
    eval
    |> Support.field(:score, %{})
    |> Support.field(key, default)
  end
end

defmodule AllbertAssistWeb.Workspace.Components.ModelsPanel do
  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssistWeb.Workspace.Components.OperatorPanels, as: Support

  @destination "workspace:models"

  @impl true
  def update(assigns, socket) do
    loaded? = Map.get(socket.assigns, :models_loaded?, false)

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:node, fn -> nil end)
      |> assign_new(:renderer_context, fn -> %{} end)
      |> assign_new(:models_loaded?, fn -> false end)
      |> assign_new(:models_diagnostics, fn -> "" end)
      |> assign_new(:model_doctor, fn -> %{summary: %{}, rows: []} end)
      |> assign_new(:model_profiles, fn -> [] end)
      |> assign_new(:provider_profiles, fn -> [] end)
      |> assign_new(:show_model_inventories?, fn -> false end)

    open? = Support.open?(socket.assigns, @destination)
    socket = assign(socket, :models_panel_open?, open?)

    if open? and not loaded? do
      {:ok, refresh(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("refresh_models", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("toggle_model_inventory", _params, socket) do
    socket = update(socket, :show_model_inventories?, &(!&1))

    if socket.assigns.show_model_inventories? do
      {:noreply, refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <article
      id="workspace-models-panel"
      class="workspace-settings-panel workspace-operator-panel"
      data-workspace-component="models_panel"
      data-workspace-renderer="component"
      data-action-source="actions-runner"
      aria-labelledby="workspace-models-panel-title"
    >
      <header class="workspace-settings-panel-header">
        <span class="workspace-card-icon" aria-hidden="true">
          <.icon name="hero-cpu-chip-micro" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <h2 id="workspace-models-panel-title" class="workspace-card-title">Models</h2>
          <p class="workspace-card-summary">
            Recommendation matrix, diagnostics, and bounded redacted inventories.
          </p>
        </div>
        <button
          type="button"
          id="workspace-models-refresh"
          class={Support.button_class!("secondary")}
          phx-click="refresh_models"
          phx-target={@myself}
        >
          Refresh
        </button>
      </header>

      <div :if={!@models_panel_open?} class="workspace-settings-panel-preview">
        Open the Models workspace tool to load action-backed model DTOs.
      </div>

      <div :if={@models_panel_open?} class="workspace-settings-panel-body">
        <p :if={@models_diagnostics != ""} id="workspace-models-diagnostics" class="text-sm">
          {@models_diagnostics}
        </p>

        <section id="workspace-models-summary" class="workspace-operator-panel-section">
          <h3 class="workspace-rail-title">Recommendation Matrix</h3>
          <div class="workspace-operator-metrics">
            <span>OK {Support.summary_count(@model_doctor.summary, "ok")}</span>
            <span>Missing {Support.summary_count(@model_doctor.summary, "missing")}</span>
            <span>Under capable {Support.summary_count(@model_doctor.summary, "under-capable")}</span>
            <span>Not pulled {Support.summary_count(@model_doctor.summary, "not-pulled")}</span>
            <span>
              Remote warnings {Support.summary_count(@model_doctor.summary, "remote-egress-warning")}
            </span>
          </div>
        </section>

        <section id="workspace-models-rows" class="workspace-operator-panel-section">
          <div
            :for={row <- @model_doctor.rows}
            id={"workspace-model-row-#{Support.safe_id(row.id)}"}
            class="workspace-operator-row"
          >
            <div class="min-w-0">
              <div class="font-medium">{row.purpose}</div>
              <div class="text-xs">
                key={row.settings_key || "future"} recommended={row.recommended_profile} configured={row.configured_profile ||
                  "none"} endpoint={row.endpoint_kind || "none"}
              </div>
              <div class="text-xs">
                diagnostics={Support.list_label(diagnostic_codes(row))}
              </div>
            </div>
            <span class={["workspace-status-pill", Support.status_class(row.status)]}>
              {Support.status_label(row.status)}
            </span>
          </div>
        </section>

        <section id="workspace-models-inventory" class="workspace-operator-panel-section">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h3 class="workspace-rail-title">Bounded Inventories</h3>
            <button
              type="button"
              id="workspace-models-inventory-toggle"
              class={Support.button_class!("secondary")}
              phx-click="toggle_model_inventory"
              phx-target={@myself}
              aria-expanded={@show_model_inventories?}
            >
              {if @show_model_inventories?, do: "Hide Rows", else: "Show Rows"}
            </button>
          </div>
          <p class="text-xs">
            Profile rows are redacted DTOs. Raw operator rows stay behind this explicit affordance.
          </p>

          <div :if={@show_model_inventories?} class="workspace-operator-split">
            <div>
              <h4 class="font-medium">Providers</h4>
              <div :for={provider <- @provider_profiles} class="workspace-operator-row">
                <div class="min-w-0">
                  <div class="font-medium">{provider.name}</div>
                  <div class="text-xs">
                    type={provider.type} endpoint={provider.endpoint_kind} enabled={inspect(
                      provider.enabled
                    )} credential={provider.credential_status}
                  </div>
                </div>
              </div>
            </div>
            <div>
              <h4 class="font-medium">Models</h4>
              <div :for={model <- @model_profiles} class="workspace-operator-row">
                <div class="min-w-0">
                  <div class="font-medium">{model.name}</div>
                  <div class="text-xs">
                    provider={model.provider} endpoint={model.provider_endpoint_kind} model={model.model} credential={model.credential_status}
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>
    </article>
    """
  end

  defp refresh(socket) do
    context = Support.action_context(socket.assigns)

    with {:ok, doctor} <-
           ActionHelper.completed_action("model_doctor", operator_report_params(), context),
         {:ok, providers} <- maybe_load_provider_profiles(socket, context),
         {:ok, models} <- maybe_load_model_profiles(socket, context) do
      assign(socket,
        models_loaded?: true,
        models_diagnostics: "",
        model_doctor: doctor.model_doctor,
        provider_profiles: providers.providers,
        model_profiles: models.models
      )
    else
      {:error, reason} ->
        assign(socket,
          models_loaded?: true,
          models_diagnostics: inspect(reason)
        )
    end
  end

  defp maybe_load_provider_profiles(socket, context) do
    if socket.assigns.show_model_inventories? do
      ActionHelper.completed_action("list_provider_profiles", operator_report_params(), context)
    else
      {:ok, %{providers: []}}
    end
  end

  defp maybe_load_model_profiles(socket, context) do
    if socket.assigns.show_model_inventories? do
      ActionHelper.completed_action("list_model_profiles", operator_report_params(), context)
    else
      {:ok, %{models: []}}
    end
  end

  defp operator_report_params do
    %{render_mode: "operator_report", surface_policy_affordance: true}
  end

  defp diagnostic_codes(row) do
    row
    |> Support.field(:diagnostics, [])
    |> Enum.map(&Support.field(&1, :code))
    |> Enum.reject(&is_nil/1)
  end
end

defmodule AllbertAssistWeb.Workspace.Components.SurfacePolicyPanel do
  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.Actions.Runner
  alias AllbertAssistWeb.Workspace.Components.OperatorPanels, as: Support

  @destination "workspace:surface_policy"

  @impl true
  def update(assigns, socket) do
    loaded? = Map.get(socket.assigns, :surface_policy_loaded?, false)

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:node, fn -> nil end)
      |> assign_new(:renderer_context, fn -> %{} end)
      |> assign_new(:surface_policy_loaded?, fn -> false end)
      |> assign_new(:surface_policy_diagnostics, fn -> "" end)
      |> assign_new(:surface_policy_notice, fn -> "" end)
      |> assign_new(:surface_policy, fn -> %{defaults: %{}, surfaces: [], effective: nil} end)

    open? = Support.open?(socket.assigns, @destination)
    socket = assign(socket, :surface_policy_panel_open?, open?)

    if open? and not loaded? do
      {:ok, refresh(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("refresh_surface_policy", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event(
        "set_surface_policy_mode",
        %{"surface" => surface, "action" => action_name, "mode" => mode},
        socket
      ) do
    context = Support.action_context(socket.assigns)

    {:ok, response} =
      Runner.run(
        "surface_policy_update",
        %{surface: surface, action: action_name, field: "render_mode", value: mode},
        context
      )

    socket =
      refresh(socket)
      |> assign(
        :surface_policy_notice,
        Support.field(response, :message, "Surface policy updated.")
      )
      |> assign(:surface_policy_diagnostics, surface_policy_diagnostics(response))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <article
      id="workspace-surface-policy-panel"
      class="workspace-settings-panel workspace-operator-panel allbert-trust-card"
      data-workspace-component="surface_policy_panel"
      data-workspace-pattern="trust-soft-card"
      data-workspace-variant="direction-c"
      data-workspace-renderer="component"
      data-action-source="actions-runner"
      aria-labelledby="workspace-surface-policy-panel-title"
    >
      <header class="workspace-settings-panel-header">
        <span class="workspace-card-icon" aria-hidden="true">
          <.icon name="hero-shield-check-micro" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <h2 id="workspace-surface-policy-panel-title" class="workspace-card-title">
            Surface Policy
          </h2>
          <p class="workspace-card-summary">
            Report mode, redaction profile, bounds, and explicit raw-row affordances.
          </p>
        </div>
        <button
          type="button"
          id="workspace-surface-policy-refresh"
          class={Support.button_class!("secondary")}
          phx-click="refresh_surface_policy"
          phx-target={@myself}
        >
          Refresh
        </button>
      </header>

      <div :if={!@surface_policy_panel_open?} class="workspace-settings-panel-preview">
        Open the Surface Policy workspace tool to load the policy DTO.
      </div>

      <div :if={@surface_policy_panel_open?} class="workspace-settings-panel-body">
        <p :if={@surface_policy_notice != ""} id="workspace-surface-policy-notice" class="text-sm">
          {@surface_policy_notice}
        </p>
        <p
          :if={@surface_policy_diagnostics != ""}
          id="workspace-surface-policy-diagnostics"
          class="text-sm"
        >
          {@surface_policy_diagnostics}
        </p>

        <section id="workspace-surface-policy-posture" class="workspace-operator-panel-section">
          <h3 class="workspace-rail-title">Default Policy</h3>
          <div class="workspace-operator-metrics">
            <span>Render {policy_default(@surface_policy, :render_mode)}</span>
            <span>Redaction {policy_default(@surface_policy, :redaction_profile)}</span>
            <span>Max rows {policy_default(@surface_policy, :max_rows)}</span>
            <span>Raw affordance {policy_default(@surface_policy, :raw_requires_affordance?)}</span>
          </div>
          <p class="text-xs">
            Security Central still decides authority; surface policy only shapes reports.
          </p>
        </section>

        <section id="workspace-surface-policy-surfaces" class="workspace-operator-panel-section">
          <h3 class="workspace-rail-title">Configured Rows</h3>
          <p :if={policy_rows(@surface_policy) == []} class="text-sm">
            No configured surface-policy rows.
          </p>
          <div
            :for={row <- policy_rows(@surface_policy)}
            id={"workspace-surface-policy-#{row.surface}-#{row.action_name}"}
            class="workspace-operator-row"
          >
            <div class="min-w-0">
              <div class="font-medium">{row.surface} / {row.action_name}</div>
              <div class="text-xs">
                report={row.render_mode} redaction={row.redaction_profile} max_rows={row.max_rows} raw_affordance={inspect(
                  row.raw_requires_affordance?
                )} source={row.source}
              </div>
            </div>
            <button
              type="button"
              id={"workspace-surface-policy-toggle-#{row.surface}-#{row.action_name}"}
              class={Support.button_class!("secondary")}
              phx-click="set_surface_policy_mode"
              phx-target={@myself}
              phx-value-surface={row.surface}
              phx-value-action={row.action_name}
              phx-value-mode={next_render_mode(row.render_mode)}
            >
              {next_render_mode_label(row.render_mode)}
            </button>
          </div>
        </section>
      </div>
    </article>
    """
  end

  defp refresh(socket) do
    context = Support.action_context(socket.assigns)

    case ActionHelper.completed_action("surface_policy_read", %{}, context) do
      {:ok, response} ->
        assign(socket,
          surface_policy_loaded?: true,
          surface_policy_diagnostics: "",
          surface_policy: response.surface_policy
        )

      {:error, reason} ->
        assign(socket,
          surface_policy_loaded?: true,
          surface_policy_diagnostics: inspect(reason)
        )
    end
  end

  defp surface_policy_diagnostics(response) do
    case Support.field(response, :status) do
      :completed -> ""
      "completed" -> ""
      status -> "Surface policy action status: #{Support.status_label(status)}"
    end
  end

  defp policy_default(policy, key) do
    policy
    |> Support.field(:defaults, %{})
    |> Support.field(key, "unknown")
    |> Support.status_label()
  end

  defp policy_rows(policy), do: Support.field(policy, :surfaces, [])

  defp next_render_mode(:operator_report), do: "assistant_summary"
  defp next_render_mode("operator_report"), do: "assistant_summary"
  defp next_render_mode(_mode), do: "operator_report"

  defp next_render_mode_label(:operator_report), do: "Use Summary"
  defp next_render_mode_label("operator_report"), do: "Use Summary"
  defp next_render_mode_label(_mode), do: "Allow Report"
end

defmodule AllbertAssistWeb.Workspace.Components.ChannelsPanel do
  @moduledoc """
  Read-only Channels/connections panel for the `workspace:channels` destination.

  v0.61 M10.3 P0-7 replaces the static placeholder with the real registered
  `operator_channels` read (redacted channel inventory through the ADR-0073 action
  boundary). Presentation-only: it reads channel status and grants no new channel
  authority; configuring a channel still routes through Security Central.
  """
  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssistWeb.Workspace.Components.OperatorPanels, as: Support

  @destination "workspace:channels"

  @impl true
  def update(assigns, socket) do
    loaded? = Map.get(socket.assigns, :channels_loaded?, false)

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:node, fn -> nil end)
      |> assign_new(:renderer_context, fn -> %{} end)
      |> assign_new(:channels_loaded?, fn -> false end)
      |> assign_new(:channels_diagnostics, fn -> "" end)
      |> assign_new(:channels_report, fn -> %{count: 0, channels: []} end)

    open? = Support.open?(socket.assigns, @destination)
    socket = assign(socket, :channels_panel_open?, open?)

    if open? and not loaded? do
      {:ok, refresh(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("refresh_channels", _params, socket), do: {:noreply, refresh(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <article
      id="workspace-channels-panel"
      class="workspace-settings-panel workspace-operator-panel"
      data-workspace-component="channels_panel"
      data-workspace-renderer="component"
      data-action-source="actions-runner"
      aria-labelledby="workspace-channels-panel-title"
    >
      <header class="workspace-settings-panel-header">
        <span class="workspace-card-icon" aria-hidden="true">
          <.icon name="hero-signal-micro" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <h2 id="workspace-channels-panel-title" class="workspace-card-title">Channels</h2>
          <p class="workspace-card-summary">
            Read-only inventory of registered channels and their configuration status.
            Configuring a channel routes through Security Central like any other capability.
          </p>
        </div>
        <button
          type="button"
          id="workspace-channels-refresh"
          class={Support.button_class!("secondary")}
          phx-click="refresh_channels"
          phx-target={@myself}
        >
          Refresh
        </button>
      </header>

      <div :if={!@channels_panel_open?} class="workspace-settings-panel-preview">
        Open the Channels workspace tool to load the channel inventory.
      </div>

      <div :if={@channels_panel_open?} class="workspace-settings-panel-body">
        <p :if={@channels_diagnostics != ""} id="workspace-channels-diagnostics" class="text-sm">
          {@channels_diagnostics}
        </p>

        <p :if={channel_rows(@channels_report) == []} id="workspace-channels-empty" class="text-sm">
          No channels are registered yet. Registered channels and their configuration status
          appear here once a channel plugin is available.
        </p>

        <div
          :for={channel <- channel_rows(@channels_report)}
          id={"workspace-channel-#{Support.safe_id(channel_field(channel, :channel))}"}
          class="workspace-operator-row"
        >
          <div class="min-w-0">
            <div class="font-medium">{Support.status_label(channel_field(channel, :channel))}</div>
            <div class="text-xs">
              provider={Support.status_label(channel_field(channel, :provider))} identities={channel_field(
                channel,
                :identity_count,
                0
              )} release={Support.status_label(channel_field(channel, :release_status, "unknown"))}
            </div>
          </div>
          <span class={["workspace-status", channel_status_class(channel)]}>
            {channel_status_label(channel)}
          </span>
        </div>
      </div>
    </article>
    """
  end

  defp refresh(socket) do
    context = Support.action_context(socket.assigns)

    case ActionHelper.completed_action("operator_channels", %{}, context) do
      {:ok, response} ->
        assign(socket,
          channels_loaded?: true,
          channels_diagnostics: "",
          channels_report: response.channels
        )

      {:error, reason} ->
        assign(socket,
          channels_loaded?: true,
          channels_diagnostics: inspect(reason)
        )
    end
  end

  defp channel_rows(report), do: Support.field(report, :channels, [])

  defp channel_field(channel, key, default \\ "unknown"),
    do: Support.field(channel, key, default)

  defp channel_status_class(channel) do
    if channel_field(channel, :enabled, false) == true,
      do: "workspace-status-success",
      else: "workspace-status-neutral"
  end

  defp channel_status_label(channel) do
    if channel_field(channel, :enabled, false) == true, do: "Enabled", else: "Not configured"
  end
end
