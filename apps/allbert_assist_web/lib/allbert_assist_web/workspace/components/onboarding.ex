defmodule AllbertAssistWeb.Workspace.Components.Onboarding do
  @moduledoc """
  First-run onboarding workspace panel — the shared guided-wizard surface.

  v0.63 M7.3: the legacy objective-backed panel is retired; this component drives the
  shared `AllbertAssist.Onboarding` wizard machine exclusively. Its steps render the
  real M3 provider setup (masked credential entry, inline doctor, provider switch, the
  three-tier vault surface) and the M4 persona review diff (current → proposed, writes
  nothing before an approved confirmation) — through the registered action spine.
  """

  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Actions.ErrorExtraction
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Maps
  alias AllbertAssist.Onboarding, as: OnboardingContext
  alias AllbertAssist.Onboarding.ProviderStep
  alias AllbertAssist.Personas
  alias AllbertAssist.Settings
  alias AllbertAssistWeb.Workspace.Components.OperatorPanels, as: PanelSupport
  alias AllbertAssistWeb.Workspace.Components.Patterns
  alias AllbertAssistWeb.PackReadiness.Component, as: ReadinessComponent

  @local_user_id "local"

  # v0.63 M2/M5: operator readiness labels — the web surface never renders a raw
  # internal probe/readiness atom (Readiness Label Mapping Contract).
  @readiness_copy %{
    ready: "Ready",
    needs_model: "Needs model",
    needs_runtime: "Needs runtime",
    needs_review: "Needs review",
    needs_credentials: "Needs credentials",
    needs_selection: "Needs model selection"
  }

  @impl true
  def mount(socket), do: ReadinessComponent.mount(socket)

  @impl true
  # v0.64.3: the parent WorkspaceLive forwards each streamed pull-progress frame here
  # via `send_update(@myself, model_pull_frame: frame)`. Append and re-render without
  # re-running the full wizard-state recompute (which would reset transient state).
  def update(%{model_pull_frame: frame} = assigns, socket) do
    case ReadinessComponent.prepare_update(assigns, socket) do
      {:ok, _assigns, socket} ->
        {:ok, assign(socket, :model_pull_progress, socket.assigns.model_pull_progress ++ [frame])}

      {:error, socket} ->
        {:ok, socket}
    end
  end

  def update(assigns, socket) do
    case ReadinessComponent.prepare_update(assigns, socket) do
      {:ok, assigns, socket} -> update_ready(assigns, socket)
      {:error, socket} -> {:ok, socket}
    end
  end

  defp update_ready(assigns, socket) do
    # M7.6: one-time first-launch reconcile of a stale v0.62 onboarding objective
    # (marker-guarded, best-effort — no-op after the first mount on a given Home).
    OnboardingContext.reconcile_stale_objective()

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:onboarding_notice, fn -> "" end)
      |> assign_new(:onboarding_error, fn -> nil end)
      |> assign_new(:selected_persona, fn -> nil end)
      |> assign_new(:persona_review, fn -> nil end)
      |> assign_new(:model_pull_progress, fn -> [] end)
      |> assign_new(:model_pulling?, fn -> false end)
      |> assign_new(:provider_form, fn -> provider_form() end)

    {:ok, refresh_state(socket)}
  end

  # -- wizard events ----------------------------------------------------------

  @impl true
  def handle_event("wizard_start", %{"track" => track}, socket) do
    OnboardingContext.wizard_start(wizard_track(track))
    {:noreply, refresh_state(assign(socket, :onboarding_notice, "Wizard started."))}
  end

  def handle_event("wizard_advance", %{"step" => step}, socket) do
    socket =
      case OnboardingContext.wizard_advance(step, %{}, effect_opts(socket)) do
        {:ok, _state} ->
          socket
          |> notify_model_disclosure_refresh()
          |> assign(onboarding_notice: "Step recorded: #{step}.", onboarding_error: nil)

        {:error, {:not_current_step, current}} ->
          assign(socket, onboarding_error: "That is not the current step (current: #{current}).")

        {:error, {:unknown_step, unknown}} ->
          assign(socket, onboarding_error: "Unknown step: #{unknown}.")
      end

    {:noreply, refresh_state(socket)}
  end

  def handle_event("wizard_rewind", %{"step" => step}, socket) do
    socket =
      case OnboardingContext.wizard_rewind(step) do
        {:ok, _state} ->
          assign(socket,
            onboarding_notice: "Returned to #{wizard_step_label(step)}.",
            onboarding_error: nil
          )

        {:error, {:not_rewindable, not_rewindable}} ->
          assign(socket, onboarding_error: "That step can't be returned to: #{not_rewindable}.")

        {:error, {:unknown_step, unknown}} ->
          assign(socket, onboarding_error: "Unknown step: #{unknown}.")
      end

    {:noreply, refresh_state(socket)}
  end

  def handle_event("wizard_enter", %{"step" => step}, socket) do
    socket =
      case OnboardingContext.wizard_enter(step) do
        {:ok, _state} ->
          assign(socket,
            onboarding_notice: "Opened #{wizard_step_label(step)}.",
            onboarding_error: nil
          )

        {:error, {:unknown_step, unknown}} ->
          assign(socket, onboarding_error: "Unknown step: #{unknown}.")
      end

    {:noreply, refresh_state(socket)}
  end

  def handle_event("reenable_model_answers", _params, socket) do
    socket =
      case OnboardingContext.reenable_model_answers(effect_opts(socket)) do
        :ok ->
          socket
          |> notify_model_disclosure_refresh()
          |> assign(
            onboarding_notice: "Model-backed answers re-enabled.",
            onboarding_error: nil,
            model_reenable_affordance?: false
          )

        {:error, reason} ->
          assign(socket, onboarding_error: reason)
      end

    {:noreply, socket |> refresh_model_readiness() |> refresh_state()}
  end

  def handle_event("wizard_reset", _params, socket) do
    OnboardingContext.wizard_reset()

    socket =
      socket
      |> assign(onboarding_notice: "Onboarding reset.", onboarding_error: nil)
      |> assign(selected_persona: nil, persona_review: nil)

    {:noreply, refresh_state(socket)}
  end

  # -- M2 local knowledge: connect a notes folder -----------------------------

  def handle_event("connect_notes_root", %{"notes_root" => path}, socket) do
    socket =
      case run_action("set_notes_root", %{path: path}, action_context(socket)) do
        {:ok, %{status: :completed} = response} ->
          assign(socket, onboarding_notice: response.message, onboarding_error: nil)

        {:ok, response} ->
          assign(socket, :onboarding_error, response_error(response))

        {:error, reason} ->
          assign(socket, :onboarding_error, reason)
      end

    {:noreply, socket}
  end

  # -- M3 provider setup ------------------------------------------------------

  def handle_event("save_provider_key", %{"provider" => provider, "api_key" => api_key}, socket) do
    socket =
      case run_action(
             "set_provider_credential",
             %{provider: provider, mode: :set_secret, api_key: api_key},
             action_context(socket)
           ) do
        {:ok, %{status: :completed}} ->
          socket
          |> notify_model_disclosure_refresh()
          |> assign(
            onboarding_notice: "Provider key stored (masked) for #{provider}.",
            onboarding_error: nil,
            provider_form: provider_form(provider)
          )

        {:ok, response} ->
          assign(socket, :onboarding_error, response_error(response))

        {:error, reason} ->
          assign(socket, :onboarding_error, reason)
      end

    {:noreply, socket |> refresh_model_readiness() |> refresh_state()}
  end

  def handle_event("run_doctor", %{"profile" => profile}, socket) do
    socket =
      case run_action("doctor_model_profile", %{profile: profile}, action_context(socket)) do
        {:ok, %{doctor: doctor}} ->
          result = ProviderStep.interpret_doctor(doctor)
          assign(socket, onboarding_notice: doctor_notice(result), onboarding_error: nil)

        {:ok, response} ->
          assign(socket, :onboarding_error, response_error(response))

        {:error, reason} ->
          assign(socket, :onboarding_error, reason)
      end

    {:noreply, socket |> refresh_model_readiness() |> refresh_state()}
  end

  def handle_event("install_runtime", _params, socket) do
    {:noreply,
     socket
     |> run_confirmed_onboarding_action(
       "install_ollama",
       %{},
       "Local runtime installation approved and started."
     )
     |> refresh_model_readiness()
     |> refresh_state()}
  end

  def handle_event("pull_model", _params, socket) do
    start_model_pull(socket, %{})
  end

  def handle_event("pull_catalog_model", %{"entry-id" => entry_id}, socket) do
    case catalog_pull_entry(socket.assigns.model_catalog, entry_id) do
      {:ok, entry} ->
        start_model_pull(socket, %{model: entry.model})

      :error ->
        {:noreply,
         assign(socket,
           onboarding_error:
             "That local catalog model is unavailable or already pulled. Refresh onboarding and try again."
         )}
    end
  end

  def handle_event("select_catalog_profile", %{"entry-id" => entry_id}, socket) do
    case catalog_selection_entry(socket.assigns.model_catalog, entry_id) do
      {:ok, entry} ->
        case run_action(
               "set_direct_answer_model_profile",
               %{profile: field(entry, :profile)},
               action_context(socket)
             ) do
          {:ok, %{status: :completed} = response} ->
            send(self(), :refresh_model_disclosure)

            {:noreply,
             socket
             |> assign(onboarding_notice: response.message, onboarding_error: nil)
             |> refresh_model_readiness()
             |> refresh_state()}

          {:ok, response} ->
            {:noreply, assign(socket, :onboarding_error, response_error(response))}

          {:error, reason} ->
            {:noreply, assign(socket, :onboarding_error, reason)}
        end

      :error ->
        {:noreply,
         assign(socket,
           onboarding_error:
             "That catalog profile is unavailable for DirectAnswer. Refresh onboarding and try again."
         )}
    end
  end

  # -- M4 persona review + apply ---------------------------------------------

  def handle_event("select_persona", %{"persona-id" => persona_id}, socket) do
    # Compute the review diff via a dry-run apply — writes nothing.
    review =
      case run_action(
             "apply_persona_profile",
             %{persona_id: persona_id, dry_run: true},
             action_context(socket)
           ) do
        {:ok, %{review: review}} -> review
        _other -> nil
      end

    {:noreply, assign(socket, selected_persona: persona_id, persona_review: review)}
  end

  def handle_event("apply_persona", %{"persona-id" => persona_id}, socket) do
    {:noreply, refresh_state(apply_persona(socket, persona_id))}
  end

  defp start_model_pull(socket, pull_params) do
    context = action_context(socket)

    params =
      pull_params
      |> maybe_put(:user_id, context.user_id)
      |> maybe_put(:thread_id, get_in(context, [:request, :thread_id]))

    # v0.64.3: register as the parent's live progress target, then run the
    # confirmation+pull asynchronously so this process stays free to receive the
    # streamed progress frames (a synchronous pull blocks and batches them).
    send(self(), {:register_model_pull_target, socket.assigns.myself})

    {:noreply,
     socket
     |> assign(model_pull_progress: [], model_pulling?: true, onboarding_error: nil)
     |> start_async(:pull_model, fn ->
       run_confirmed_onboarding_action_async("pull_model", params, context)
     end)}
  end

  # v0.64.3: finalize the async model pull started in `handle_event("pull_model", ...)`.
  # Streamed progress frames arrive separately via the targeted `update/2` clause.
  @impl true
  def handle_async(:pull_model, {:ok, {:ok, %{status: :completed} = response}}, socket) do
    notify_first_model_enablement(response)

    {:noreply,
     socket
     |> assign(:model_pulling?, false)
     |> assign_action_success(response_message(response), response)
     |> refresh_model_readiness()
     |> refresh_state()}
  end

  def handle_async(:pull_model, {:ok, {:ok, response}}, socket) do
    {:noreply,
     socket
     |> assign(model_pulling?: false, onboarding_error: response_error(response))
     |> refresh_state()}
  end

  def handle_async(:pull_model, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(model_pulling?: false, onboarding_error: reason)
     |> refresh_state()}
  end

  def handle_async(:pull_model, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(model_pulling?: false, onboarding_error: "Model pull crashed: #{inspect(reason)}")
     |> refresh_state()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <article
      id="workspace-onboarding-panel"
      class="workspace-settings-panel"
      data-workspace-component="onboarding_panel"
      data-workspace-renderer="component"
      aria-labelledby="workspace-onboarding-title"
    >
      <header class="workspace-card-header">
        <span class="workspace-card-icon" aria-hidden="true">
          <.icon name="hero-sparkles-micro" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <h2 id="workspace-onboarding-title" class="workspace-card-title">Onboarding</h2>
          <p class="workspace-card-summary">Guided first-run provider, model, and profile setup.</p>
        </div>
      </header>

      <div :if={@onboarding_notice != ""} class="alert alert-success mt-3 text-sm">
        {@onboarding_notice}
      </div>

      <div :if={@onboarding_error} class="alert alert-error mt-3 text-sm">
        {inspect(@onboarding_error)}
      </div>

      <section
        :if={@onboarding_wizard}
        id="workspace-onboarding-wizard"
        class="mt-4 space-y-3 rounded border border-base-300 p-3"
        data-wizard-track={@onboarding_wizard.track}
        data-wizard-step={@onboarding_wizard.step}
        data-wizard-complete={to_string(@onboarding_wizard.complete?)}
      >
        <div class="flex items-center justify-between text-sm">
          <span class="font-medium">Guided setup</span>
          <span
            id="workspace-onboarding-readiness"
            class="badge badge-sm"
            data-readiness={@onboarding_wizard.readiness}
          >
            {readiness_label(@onboarding_wizard.readiness)}
          </span>
        </div>

        <div
          :if={@onboarding_wizard.started? and @first_chat_ready?}
          id="workspace-onboarding-first-chat-ready"
          class="rounded border border-success/40 bg-success/10 px-2 py-1.5 text-xs"
          role="status"
        >
          <span class="font-medium">You're ready to chat.</span>
          Ask your first question in the chat — for example, "What can you do locally?"
          Risky actions still pause for your approval.
        </div>

        <div :if={!@onboarding_wizard.started?} class="flex gap-2">
          <button
            type="button"
            id="workspace-onboarding-start-quickstart"
            class={Patterns.button_class!("primary")}
            phx-click="wizard_start"
            phx-value-track="quickstart"
            phx-target={@myself}
          >
            Start QuickStart
          </button>
          <button
            type="button"
            id="workspace-onboarding-start-advanced"
            class={Patterns.button_class!("secondary")}
            phx-click="wizard_start"
            phx-value-track="advanced"
            phx-target={@myself}
          >
            Advanced
          </button>
        </div>

        <ol class="space-y-1 text-sm">
          <li
            :for={step <- OnboardingContext.wizard_steps()}
            id={"workspace-wizard-step-#{step}"}
            class="flex items-center justify-between"
            data-current={to_string(step == @onboarding_wizard.step)}
            data-done={to_string(step in @onboarding_wizard.done)}
          >
            <button
              :if={step in @onboarding_wizard.done and !@onboarding_wizard.complete?}
              type="button"
              id={"workspace-wizard-rewind-#{step}"}
              class={Patterns.button_class!("secondary", "workspace-button-compact px-0")}
              phx-click="wizard_rewind"
              phx-value-step={step}
              phx-target={@myself}
            >
              {wizard_step_label(step)}
            </button>
            <button
              :if={step not in @onboarding_wizard.done or @onboarding_wizard.complete?}
              type="button"
              id={"workspace-wizard-enter-#{step}"}
              class={Patterns.button_class!("secondary", "workspace-button-compact px-0")}
              phx-click="wizard_enter"
              phx-value-step={step}
              phx-target={@myself}
            >
              {wizard_step_label(step)}
            </button>
            <button
              :if={
                @onboarding_wizard.started? and step == @onboarding_wizard.step and
                  !@onboarding_wizard.complete?
              }
              type="button"
              id={"workspace-wizard-advance-#{step}"}
              class={Patterns.compact_button_class!("primary")}
              phx-click="wizard_advance"
              phx-value-step={step}
              phx-target={@myself}
            >
              Continue
            </button>
          </li>
        </ol>

        <div
          :if={
            @onboarding_wizard.started? and
              (!@onboarding_wizard.complete? or @onboarding_wizard.editing?)
          }
          id="workspace-wizard-step-controls"
          class="rounded border border-base-200 p-3 text-sm"
        >
          {render_step_controls(assigns)}
        </div>

        <div
          :if={@model_reenable_affordance?}
          id="workspace-model-reenable-affordance"
          class="rounded border border-warning/40 bg-warning/10 p-2 text-sm"
        >
          <p>Model-backed answers are explicitly disabled. Re-enable them?</p>
          <button
            type="button"
            id="workspace-model-reenable"
            class={Patterns.compact_button_class!("primary")}
            phx-click="reenable_model_answers"
            phx-target={@myself}
          >
            Re-enable model answers
          </button>
        </div>

        <div :if={@onboarding_wizard.started?}>
          <button
            type="button"
            id="workspace-onboarding-wizard-reset"
            class={Patterns.compact_button_class!("secondary")}
            phx-click="wizard_reset"
            phx-target={@myself}
          >
            Reset onboarding
          </button>
        </div>

        <section id="workspace-onboarding-trust-spine" class="mt-2 border-t border-base-300 pt-2">
          <div class="text-xs font-medium text-base-content/70">
            The trust spine — what keeps first-run safe
          </div>
          <p
            :if={@step_guidance}
            id="workspace-onboarding-step-guidance"
            class="mt-1 text-xs text-base-content/70"
          >
            {@step_guidance.guidance}
          </p>
          <ul class="mt-1 space-y-0.5 text-xs text-base-content/60">
            <li :for={line <- trust_lines(@step_guidance)}>{line}</li>
          </ul>
        </section>
      </section>
    </article>
    """
  end

  # -- per-step control panels ------------------------------------------------

  defp render_step_controls(%{onboarding_wizard: %{step: "model_path"}} = assigns) do
    ~H"""
    <div id="workspace-wizard-provider" class="space-y-3">
      <section id="workspace-model-path-repair" class="space-y-2">
        <p id="workspace-direct-answer-readiness" class="text-xs text-base-content/70">
          DirectAnswer: {readiness_label(@onboarding_wizard.direct_answer_readiness)}
        </p>
        <p class="text-xs font-medium text-base-content/80">{@model_guidance.headline}</p>
        <p class="text-xs text-base-content/70">{@model_guidance.next_action}</p>

        <div class="flex flex-wrap gap-2">
          <button
            :if={@model_guidance.action == :install_runtime}
            type="button"
            id="workspace-model-install-runtime"
            class={Patterns.button_class!("primary")}
            phx-click="install_runtime"
            phx-target={@myself}
          >
            Install local runtime
          </button>
          <button
            :if={@model_guidance.action == :pull_model}
            type="button"
            id="workspace-model-pull"
            class={Patterns.button_class!("primary")}
            phx-click="pull_model"
            phx-target={@myself}
            disabled={@model_pulling?}
          >
            {if @model_pulling?, do: "Pulling starter model…", else: "Pull starter model"}
          </button>
        </div>

        <ol
          :if={@model_pull_progress != []}
          id="workspace-model-pull-progress"
          class="space-y-1 text-xs text-base-content/70"
        >
          <li :for={progress <- @model_pull_progress}>
            {progress.status}<span :if={Map.get(progress, :percent)}> — {progress.percent}%</span>
          </li>
        </ol>
      </section>

      <p class="text-xs text-base-content/70">{@tier_line}</p>

      <div id="workspace-onboarding-model-catalog" class="space-y-1">
        <div
          :for={entry <- onboarding_catalog(@model_catalog)}
          id={"workspace-onboarding-catalog-row-#{PanelSupport.safe_id(entry.id)}"}
          class="flex items-center justify-between gap-2 rounded border border-base-200 p-2 text-xs"
        >
          <div class="min-w-0">
            <span class="font-medium">{entry.label}</span>
            <span>{" — #{entry.model}"}</span>
            <span :if={entry.floor_gb}>{" · floor #{entry.floor_gb} GB"}</span>
            <span>{" · #{Enum.join(entry.purposes, ", ")}"}</span>
            <span :if={catalog_model_pullable?(entry)}> · pull requires confirmation</span>
          </div>
          <button
            :if={catalog_model_pullable?(entry)}
            type="button"
            id={"workspace-onboarding-catalog-pull-#{PanelSupport.safe_id(entry.id)}"}
            class={Patterns.button_class!("secondary")}
            phx-click="pull_catalog_model"
            phx-value-entry-id={entry.id}
            phx-target={@myself}
            disabled={@model_pulling?}
          >
            {if @model_pulling?, do: "Pull in progress…", else: "Pull #{entry.model}"}
          </button>
          <button
            :if={catalog_model_selectable?(entry)}
            type="button"
            id={"workspace-onboarding-catalog-use-#{PanelSupport.safe_id(entry.id)}"}
            class={Patterns.button_class!("secondary")}
            phx-click="select_catalog_profile"
            phx-value-entry-id={entry.id}
            phx-target={@myself}
          >
            Use for answers
          </button>
        </div>
      </div>

      <.form
        for={@provider_form}
        phx-submit="save_provider_key"
        phx-target={@myself}
        class="space-y-2"
      >
        <select id="workspace-provider-select" name="provider" class="select select-sm w-full">
          <option
            :for={p <- @provider_profiles}
            value={p.name}
            selected={p.name == @provider_form.params["provider"]}
          >
            {p.name}
          </option>
        </select>
        <input
          id="workspace-provider-key"
          type="password"
          name="api_key"
          autocomplete="off"
          placeholder="Provider key (stored masked in the vault)"
          class="input input-sm w-full"
        />
        <button type="submit" id="workspace-provider-save" class={Patterns.button_class!("primary")}>
          Store key (masked)
        </button>
      </.form>

      <div class="flex flex-wrap gap-2">
        <button
          type="button"
          id="workspace-provider-doctor"
          class={Patterns.compact_button_class!("secondary")}
          phx-click="run_doctor"
          phx-target={@myself}
          phx-value-profile="local"
        >
          Run doctor
        </button>
      </div>
    </div>
    """
  end

  defp render_step_controls(%{onboarding_wizard: %{step: "profile_select"}} = assigns) do
    ~H"""
    <div id="workspace-wizard-personas" class="flex flex-wrap gap-2">
      <button
        :for={persona <- Personas.all()}
        type="button"
        id={"workspace-persona-#{persona["persona_id"]}"}
        class={
          Patterns.compact_button_class!(
            if @selected_persona == persona["persona_id"], do: "primary", else: "secondary"
          )
        }
        phx-click="select_persona"
        phx-target={@myself}
        phx-value-persona-id={persona["persona_id"]}
      >
        {persona["label"]}
      </button>
    </div>
    """
  end

  defp render_step_controls(%{onboarding_wizard: %{step: "profile_review"}} = assigns) do
    ~H"""
    <div id="workspace-wizard-persona-review">
      <p :if={!@persona_review} class="text-xs text-base-content/70">
        Pick a persona at the previous step to review what it seeds.
      </p>

      <div :if={@persona_review} id="workspace-persona-review-diff" class="space-y-2">
        <div class="text-xs font-medium">
          Review — {@persona_review.persona_id} ({@persona_review.change_count} change(s)). Nothing is written until you apply.
        </div>
        <ul class="space-y-0.5 text-xs">
          <li :for={change <- @persona_review.changes} class="flex justify-between gap-2">
            <span class="font-mono">{change.key}</span>
            <span class="text-base-content/70">
              {inspect(change.current)} → {inspect(change.proposed)}
            </span>
          </li>
        </ul>
        <button
          type="button"
          id="workspace-persona-apply"
          class={Patterns.button_class!("primary")}
          phx-click="apply_persona"
          phx-target={@myself}
          phx-value-persona-id={@persona_review.persona_id}
        >
          Apply {@persona_review.persona_id}
        </button>
      </div>
    </div>
    """
  end

  defp render_step_controls(%{onboarding_wizard: %{step: "first_chat"}} = assigns) do
    assigns = assign(assigns, :first_chat_prompts, OnboardingContext.first_chat_prompts())

    ~H"""
    <div id="workspace-wizard-first-chat">
      <div class="text-xs font-medium text-base-content/70">Try a first chat</div>
      <ul :if={@first_chat_prompts != []} class="mt-1 space-y-0.5 text-xs">
        <li :for={prompt <- @first_chat_prompts} class="text-base-content/80">“{prompt}”</li>
      </ul>

      <div id="workspace-wizard-connect-notes" class="mt-3 space-y-1">
        <div class="text-xs font-medium text-base-content/70">Connect a notes folder</div>
        <p class="text-xs text-base-content/60">
          Point Allbert at a local folder to ask about your own notes. You can change this
          later; Allbert only reads inside the folder you choose.
        </p>
        <form phx-submit="connect_notes_root" phx-target={@myself} class="flex gap-2">
          <input
            type="text"
            name="notes_root"
            id="workspace-wizard-notes-root"
            placeholder="/path/to/your/notes"
            class="input input-sm input-bordered flex-1 text-xs"
          />
          <button
            type="submit"
            id="workspace-wizard-connect-notes-submit"
            class={Patterns.button_class!("primary")}
          >
            Connect
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp render_step_controls(assigns) do
    ~H"""
    <p class="text-xs text-base-content/70">
      Continue when this step is ready.
    </p>
    """
  end

  # -- state / helpers --------------------------------------------------------

  # Cache the substrate probe and the matching DirectAnswer projection as one
  # snapshot. Wizard navigation is presentation-only; model/provider mutations
  # explicitly refresh the pair through `refresh_model_readiness/1`.
  defp ensure_model_readiness(socket) do
    if Map.has_key?(socket.assigns, :onboarding_probe) and
         Map.has_key?(socket.assigns, :onboarding_enablement_result) do
      socket
    else
      refresh_model_readiness(socket)
    end
  end

  defp refresh_model_readiness(socket) do
    context = %{allbert_pack_epoch: socket.assigns.allbert_pack_epoch}
    probe = OnboardingContext.safe_first_model_state(context: context)
    projection = FirstRun.readiness_projection(model_state: probe, context: context)

    assign(socket,
      onboarding_probe: probe,
      onboarding_enablement_result: projection.enablement_result
    )
  end

  defp refresh_state(socket) do
    socket = ensure_model_readiness(socket)

    wizard =
      OnboardingContext.wizard_state(
        first_model_state: socket.assigns.onboarding_probe,
        enablement_result: socket.assigns.onboarding_enablement_result,
        context: %{allbert_pack_epoch: socket.assigns.allbert_pack_epoch}
      )

    socket
    |> assign(:onboarding_wizard, wizard)
    |> assign(
      :model_guidance,
      OnboardingContext.model_guidance_for(wizard.direct_answer_readiness, wizard.track)
    )
    |> assign(:step_guidance, step_guidance(wizard))
    |> assign(:first_chat_ready?, OnboardingContext.first_chat_ready?(wizard))
    |> assign(
      :model_reenable_affordance?,
      Map.get(socket.assigns, :model_reenable_affordance?, false) or
        claim_reenable_affordance(wizard, socket)
    )
    |> assign(:provider_profiles, provider_profiles())
    |> assign(:model_catalog, model_catalog(socket))
    |> assign(:tier_line, tier_line())
  end

  # v1.0 R3: contextual guidance for the current step while onboarding is in
  # progress; a not-started or completed wizard falls back to the full spine.
  defp step_guidance(%{started?: true, complete?: false, step: step}),
    do: OnboardingContext.step_guidance(step)

  defp step_guidance(%{started?: true, editing?: true, step: step}),
    do: OnboardingContext.step_guidance(step)

  defp step_guidance(_wizard), do: nil

  defp claim_reenable_affordance(%{step: "model_path"}, socket) do
    if connected?(socket), do: OnboardingContext.claim_model_reenable_affordance(), else: false
  end

  defp claim_reenable_affordance(_wizard, _socket), do: false

  defp trust_lines(nil), do: OnboardingContext.trust_spine()
  defp trust_lines(%{trust_lines: lines}), do: lines

  defp model_catalog(socket) do
    case run_action("list_model_catalog", %{}, action_context(socket)) do
      {:ok, %{status: :completed, entries: entries}} -> entries
      _error -> []
    end
  end

  # v0.64.3: async variant used by the live-progress pull. Returns the raw Runner
  # result tuple so `handle_async/3` finalizes the socket on the component.
  defp run_confirmed_onboarding_action_async(action, params, context) do
    case run_action(action, params, context) do
      {:ok, %{status: :needs_confirmation, confirmation_id: id}} ->
        run_action("approve_confirmation", %{id: id, reason: "onboarding #{action}"}, context)

      other ->
        other
    end
  end

  defp run_confirmed_onboarding_action(socket, action, params, success_notice) do
    context = action_context(socket)

    case run_action(action, params, context) do
      {:ok, %{status: :needs_confirmation, confirmation_id: id}} ->
        approve_onboarding_action(socket, action, id, context, success_notice)

      {:ok, %{status: :completed} = response} ->
        assign_action_success(socket, success_notice, response)

      {:ok, response} ->
        assign(socket, :onboarding_error, response_error(response))

      {:error, reason} ->
        assign(socket, :onboarding_error, reason)
    end
  end

  defp approve_onboarding_action(socket, action, confirmation_id, context, success_notice) do
    case run_action(
           "approve_confirmation",
           %{id: confirmation_id, reason: "onboarding #{action}"},
           context
         ) do
      {:ok, %{status: :completed} = response} ->
        assign_action_success(socket, success_notice, response)

      {:ok, response} ->
        assign(socket, :onboarding_error, response_error(response))

      {:error, reason} ->
        assign(socket, :onboarding_error, reason)
    end
  end

  defp assign_action_success(socket, notice, response) do
    socket
    |> assign(onboarding_notice: notice, onboarding_error: nil)
    |> maybe_assign_pull_progress(response)
  end

  defp maybe_assign_pull_progress(socket, %{progress: progress}) when is_list(progress),
    do: assign(socket, :model_pull_progress, progress)

  defp maybe_assign_pull_progress(socket, _response), do: socket

  defp notify_first_model_enablement(response) do
    send(self(), :refresh_model_disclosure)
    output_data = Map.get(response, :output_data) || Map.get(response, "output_data") || %{}

    case Map.get(output_data, :enablement) || Map.get(output_data, "enablement") do
      %{} = result -> send(self(), {:first_model_enablement_changed, result})
      _missing_or_failed -> :ok
    end
  end

  defp notify_model_disclosure_refresh(socket) do
    send(self(), :refresh_model_disclosure)
    socket
  end

  defp response_message(response) do
    output_data = Map.get(response, :output_data) || Map.get(response, "output_data") || %{}

    Map.get(output_data, :enablement_operator_message) ||
      Map.get(output_data, "enablement_operator_message") ||
      Map.get(response, :message) || Map.get(response, "message") ||
      "Model pull approved and completed."
  end

  defp catalog_pull_entry(entries, entry_id) when is_list(entries) and is_binary(entry_id) do
    case Enum.find(entries, fn entry ->
           field(entry, :id) == entry_id and catalog_model_pullable?(entry)
         end) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  defp catalog_pull_entry(_entries, _entry_id), do: :error

  defp catalog_model_pullable?(entry), do: field(entry, :direct_answer_repair?) == true

  defp catalog_selection_entry(entries, entry_id)
       when is_list(entries) and is_binary(entry_id) do
    case Enum.find(entries, fn entry ->
           field(entry, :id) == entry_id and catalog_model_selectable?(entry)
         end) do
      nil ->
        :error

      entry ->
        case field(entry, :profile) do
          profile when is_binary(profile) and profile != "" -> {:ok, entry}
          _missing_or_invalid -> :error
        end
    end
  end

  defp catalog_selection_entry(_entries, _entry_id), do: :error

  defp catalog_model_selectable?(entry), do: field(entry, :selectable?) == true

  defp onboarding_catalog(entries) when is_list(entries) do
    {actionable, informational} =
      entries
      |> Enum.sort_by(&field(&1, :id))
      |> Enum.split_with(fn entry ->
        catalog_model_pullable?(entry) or catalog_model_selectable?(entry)
      end)

    actionable ++ Enum.take(informational, max(12 - length(actionable), 0))
  end

  defp onboarding_catalog(_entries), do: []

  defp apply_persona(socket, persona_id) do
    context = action_context(socket)

    with {:ok, %{status: :needs_confirmation, confirmation_id: id}} <-
           run_action("apply_persona_profile", %{persona_id: persona_id}, context),
         {:ok, %{status: :completed}} <-
           run_action(
             "approve_confirmation",
             %{id: id, reason: "onboarding persona apply"},
             context
           ) do
      # M7.4: record the applied persona so the first_chat step suggests its prompts.
      OnboardingContext.record_applied_persona(persona_id)

      assign(socket,
        onboarding_notice: "Applied persona #{persona_id}.",
        onboarding_error: nil,
        persona_review: nil
      )
    else
      {:ok, response} -> assign(socket, :onboarding_error, response_error(response))
      {:error, reason} -> assign(socket, :onboarding_error, reason)
    end
  end

  defp provider_profiles do
    case Settings.list_provider_profiles() do
      {:ok, profiles} -> profiles
      _other -> []
    end
  end

  defp tier_line do
    report = ProviderStep.vault_tier_report()

    if report.writable? do
      "New provider keys are stored in: #{report.label}."
    else
      "This tier (#{report.label}) can't store new keys; set a provider key in the environment or enable the OS/encrypted vault."
    end
  rescue
    _error -> ""
  end

  defp provider_form(provider \\ "openai") do
    to_form(%{"provider" => provider, "api_key" => ""}, as: nil)
  end

  defp doctor_notice(%{ok?: true, headline: headline}), do: headline

  defp doctor_notice(%{headline: headline, next_action: action}) when is_binary(action),
    do: "#{headline} #{action}"

  defp doctor_notice(%{headline: headline}), do: headline

  defp readiness_label(readiness), do: Map.get(@readiness_copy, readiness, "Unknown")

  defp wizard_track("advanced"), do: :advanced
  defp wizard_track(_quickstart), do: :quickstart

  defp wizard_step_label(step) do
    step
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp run_action(name, params, context), do: apply(Runner, :run, [name, params, context])

  defp response_error(response), do: ErrorExtraction.from_response(response)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp action_context(socket) do
    context = Map.get(socket.assigns, :renderer_context, %{})
    user_id = user_id(context)

    %{
      actor: user_id,
      user_id: user_id,
      channel: :live_view,
      surface: "/workspace",
      allbert_pack_epoch: socket.assigns.allbert_pack_epoch,
      request: %{
        user_id: user_id,
        operator_id: user_id,
        channel: :live_view,
        thread_id: field(context, :thread_id)
      }
    }
  end

  # `action_context/1` is a Settings-write context (actor, channel, surface,
  # request) that happens to carry the epoch. It used to travel under
  # `:effect_context`, colliding with the epoch-carrier key of the same name.
  # It now has its own key, and the epoch travels under the one convention.
  defp effect_opts(socket) do
    context = action_context(socket)

    [settings_context: context, allbert_pack_epoch: context.allbert_pack_epoch]
  end

  defp user_id(context), do: field(context, :user_id) || @local_user_id

  defp field(map, key), do: Maps.field_truthy(map, key)
end
