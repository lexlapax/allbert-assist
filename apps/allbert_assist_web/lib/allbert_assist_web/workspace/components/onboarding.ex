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
  alias AllbertAssist.Onboarding, as: OnboardingContext
  alias AllbertAssist.Onboarding.ProviderStep
  alias AllbertAssist.Personas
  alias AllbertAssist.Settings

  # v0.63 M2/M5: operator readiness labels — the web surface never renders a raw
  # internal probe/readiness atom (Readiness Label Mapping Contract).
  @readiness_copy %{
    ready: "Ready",
    needs_model: "Needs model",
    needs_runtime: "Needs runtime",
    needs_review: "Needs review",
    needs_credentials: "Needs credentials"
  }

  @impl true
  def update(assigns, socket) do
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
      |> assign_new(:provider_form, fn -> provider_form() end)

    {:ok, refresh_state(socket)}
  end

  # -- wizard events ----------------------------------------------------------

  @impl true
  def handle_event("wizard_start", %{"track" => track}, socket) do
    OnboardingContext.wizard_start(wizard_track(track))
    {:noreply, refresh_state(reprobe(assign(socket, :onboarding_notice, "Wizard started.")))}
  end

  def handle_event("wizard_advance", %{"step" => step}, socket) do
    socket =
      case OnboardingContext.wizard_advance(step) do
        {:ok, _state} ->
          assign(socket, onboarding_notice: "Step recorded: #{step}.", onboarding_error: nil)

        {:error, {:not_current_step, current}} ->
          assign(socket, onboarding_error: "That is not the current step (current: #{current}).")

        {:error, {:unknown_step, unknown}} ->
          assign(socket, onboarding_error: "Unknown step: #{unknown}.")
      end

    {:noreply, refresh_state(reprobe(socket))}
  end

  def handle_event("wizard_reset", _params, socket) do
    OnboardingContext.wizard_reset()

    socket =
      socket
      |> assign(onboarding_notice: "Onboarding reset.", onboarding_error: nil)
      |> assign(selected_persona: nil, persona_review: nil)

    {:noreply, refresh_state(reprobe(socket))}
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
          assign(socket,
            onboarding_notice: "Provider key stored (masked) for #{provider}.",
            onboarding_error: nil,
            provider_form: provider_form(provider)
          )

        {:ok, response} ->
          assign(socket, :onboarding_error, response_error(response))

        {:error, reason} ->
          assign(socket, :onboarding_error, reason)
      end

    {:noreply, refresh_state(reprobe(socket))}
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

    {:noreply, refresh_state(reprobe(socket))}
  end

  def handle_event("use_provider", %{"profile" => profile}, socket) do
    socket =
      case run_action("set_active_model_profile", %{profile: profile}, action_context(socket)) do
        {:ok, %{status: :completed}} ->
          assign(socket,
            onboarding_notice:
              "Active provider/model set to #{profile} (settings write, no config edit).",
            onboarding_error: nil
          )

        {:ok, response} ->
          assign(socket, :onboarding_error, response_error(response))

        {:error, reason} ->
          assign(socket, :onboarding_error, reason)
      end

    {:noreply, refresh_state(reprobe(socket))}
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

        <div :if={!@onboarding_wizard.started?} class="flex gap-2">
          <button
            type="button"
            id="workspace-onboarding-start-quickstart"
            class="btn btn-sm btn-primary"
            phx-click="wizard_start"
            phx-value-track="quickstart"
            phx-target={@myself}
          >
            Start QuickStart
          </button>
          <button
            type="button"
            id="workspace-onboarding-start-advanced"
            class="btn btn-sm"
            phx-click="wizard_start"
            phx-value-track="advanced"
            phx-target={@myself}
          >
            Advanced
          </button>
        </div>

        <ol :if={@onboarding_wizard.started?} class="space-y-1 text-sm">
          <li
            :for={step <- OnboardingContext.wizard_steps()}
            id={"workspace-wizard-step-#{step}"}
            class="flex items-center justify-between"
            data-current={to_string(step == @onboarding_wizard.step)}
            data-done={to_string(step in @onboarding_wizard.done)}
          >
            <span>{wizard_step_label(step)}</span>
            <button
              :if={step == @onboarding_wizard.step and !@onboarding_wizard.complete?}
              type="button"
              id={"workspace-wizard-advance-#{step}"}
              class="btn btn-xs btn-primary"
              phx-click="wizard_advance"
              phx-value-step={step}
              phx-target={@myself}
            >
              Continue
            </button>
          </li>
        </ol>

        <div
          :if={@onboarding_wizard.started? and !@onboarding_wizard.complete?}
          id="workspace-wizard-step-controls"
          class="rounded border border-base-200 p-3 text-sm"
        >
          {render_step_controls(assigns)}
        </div>

        <div :if={@onboarding_wizard.started?}>
          <button
            type="button"
            id="workspace-onboarding-wizard-reset"
            class="btn btn-xs btn-ghost"
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
          <ul class="mt-1 space-y-0.5 text-xs text-base-content/60">
            <li :for={line <- OnboardingContext.trust_spine()}>{line}</li>
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
      <p class="text-xs text-base-content/70">{@tier_line}</p>

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
        <button type="submit" id="workspace-provider-save" class="btn btn-sm btn-primary">
          Store key (masked)
        </button>
      </.form>

      <div class="flex flex-wrap gap-2">
        <button
          :for={p <- @provider_profiles}
          type="button"
          id={"workspace-provider-use-#{p.name}"}
          class="btn btn-xs"
          phx-click="use_provider"
          phx-target={@myself}
          phx-value-profile={p.name}
        >
          Use {p.name}
        </button>
        <button
          type="button"
          id="workspace-provider-doctor"
          class="btn btn-xs btn-ghost"
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
        class={["btn btn-xs", @selected_persona == persona["persona_id"] && "btn-primary"]}
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
          class="btn btn-sm btn-primary"
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

  defp render_step_controls(assigns) do
    ~H"""
    <p class="text-xs text-base-content/70">
      Continue when this step is ready.
    </p>
    """
  end

  # -- state / helpers --------------------------------------------------------

  # M7.2: probe once per component, refreshed only on wizard actions.
  defp ensure_probe(socket) do
    if Map.get(socket.assigns, :onboarding_probe) do
      socket
    else
      assign(socket, :onboarding_probe, OnboardingContext.safe_first_model_state())
    end
  end

  defp reprobe(socket),
    do: assign(socket, :onboarding_probe, OnboardingContext.safe_first_model_state())

  defp refresh_state(socket) do
    socket = ensure_probe(socket)

    wizard =
      OnboardingContext.wizard_state(first_model_state: socket.assigns.onboarding_probe)

    socket
    |> assign(:onboarding_wizard, wizard)
    |> assign(:provider_profiles, provider_profiles())
    |> assign(:tier_line, tier_line())
  end

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

  defp action_context(socket) do
    context = Map.get(socket.assigns, :renderer_context, %{})
    user_id = user_id(context)

    %{
      actor: user_id,
      user_id: user_id,
      channel: :live_view,
      surface: "/workspace",
      request: %{
        user_id: user_id,
        operator_id: user_id,
        channel: :live_view,
        thread_id: field(context, :thread_id)
      }
    }
  end

  defp user_id(context), do: field(context, :user_id) || "local"

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil
end
