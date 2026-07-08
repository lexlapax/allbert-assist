defmodule AllbertAssistWeb.Workspace.Components.Onboarding do
  @moduledoc """
  First-run onboarding workspace panel.
  """

  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Actions.ErrorExtraction
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Onboarding, as: OnboardingContext
  alias AllbertAssist.Surface.Renderer, as: SurfaceRenderer
  alias AllbertAssistWeb.Workspace.Components.Patterns

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
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:onboarding_notice, fn -> "" end)
      |> assign_new(:onboarding_error, fn -> nil end)

    {:ok, refresh_state(socket)}
  end

  # v0.63 M5: the shared M1 guided-wizard events. Both surfaces (web/terminal) drive
  # identical step IDs; these call the M1 state machine directly (marker-backed, not
  # a store write), then refresh.
  @impl true
  def handle_event("wizard_start", %{"track" => track}, socket) do
    OnboardingContext.wizard_start(wizard_track(track))
    {:noreply, refresh_state(assign(socket, :onboarding_notice, "Wizard started."))}
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

    {:noreply, refresh_state(socket)}
  end

  def handle_event("wizard_reset", _params, socket) do
    OnboardingContext.wizard_reset()

    {:noreply,
     refresh_state(assign(socket, onboarding_notice: "Onboarding reset.", onboarding_error: nil))}
  end

  def handle_event("complete_step", %{"step-id" => step_id}, socket) do
    {:noreply, record_step(socket, step_id, "completed", "Workspace onboarding step completed.")}
  end

  def handle_event("skip_step", %{"step-id" => step_id}, socket) do
    {:noreply, record_step(socket, step_id, "skipped", "Workspace onboarding step skipped.")}
  end

  def handle_event("channel_choice", %{"choice" => choice, "step-id" => step_id}, socket) do
    {outcome, note} =
      case choice do
        "none" ->
          {"skipped", "Operator skipped channel registration."}

        "telegram" ->
          {"selected",
           "Operator selected Telegram channel registration; setup is deferred until configured."}

        "email" ->
          {"selected",
           "Operator selected email channel registration; setup is deferred until configured."}

        _choice ->
          {"skipped", "Operator skipped channel registration."}
      end

    {:noreply, record_step(socket, step_id, outcome, note)}
  end

  def handle_event("use_model_profile", %{"profile" => profile}, socket) do
    context = action_context(socket)

    socket =
      case run_action("set_active_model_profile", %{profile: profile}, context) do
        {:ok, %{status: :completed, message: message}} ->
          socket
          |> record_current_step("completed", message)
          |> put_flash_notice("Model profile saved.")

        {:ok, response} ->
          assign(socket, :onboarding_error, response_error(response))

        {:error, reason} ->
          assign(socket, :onboarding_error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("doctor_model_profile", _params, socket) do
    context = action_context(socket)
    profile = active_model_profile(socket)

    socket =
      case run_action("doctor_model_profile", %{profile: profile}, context) do
        {:ok, %{status: :completed, doctor: doctor} = response} ->
          note =
            "Doctor #{profile}: endpoint_kind=#{doctor.endpoint_kind}, endpoint_ok=#{doctor.endpoint_ok}, credential_ok=#{inspect(doctor.credential_ok)}, model_available=#{inspect(doctor.model_available)}, redacted_host=#{doctor.redacted_host}."

          socket
          |> record_current_step("completed", note)
          |> put_flash_notice(response_text(response))

        {:ok, response} ->
          assign(socket, :onboarding_error, response_error(response))

        {:error, reason} ->
          assign(socket, :onboarding_error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("set_model_assist", %{"enabled" => enabled}, socket) do
    context = action_context(socket)
    profile = active_model_profile(socket)

    socket =
      case run_action(
             "set_active_model_profile",
             %{profile: profile, enable_assist: enabled == "true"},
             context
           ) do
        {:ok, %{status: :completed, message: message}} ->
          socket
          |> record_current_step("completed", message)
          |> put_flash_notice("Model-assisted intent updated.")

        {:ok, response} ->
          assign(socket, :onboarding_error, response_error(response))

        {:error, reason} ->
          assign(socket, :onboarding_error, reason)
      end

    {:noreply, socket}
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
          <p class="workspace-card-summary">First-run provider, model, and channel setup.</p>
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

      <div :if={@onboarding_state} class="mt-4 space-y-4">
        <section class="space-y-1 text-sm">
          <div class="font-medium">{@onboarding_state.objective.title}</div>
          <div>Status: {@onboarding_state.objective.status}</div>
          <div>Progress: {@onboarding_state.objective.progress_summary}</div>
          <div :if={@onboarding_state.current_step}>
            Current: {@onboarding_state.current_step.index}. {@onboarding_state.current_step.title}
          </div>
          <div :if={!@onboarding_state.current_step}>Current: complete</div>
        </section>

        <section :if={@onboarding_state.current_step} class="space-y-3">
          <div class="rounded border border-base-300 p-3 text-sm">
            <div class="font-medium">{@onboarding_state.current_step.title}</div>
            <p class="mt-1 text-base-content/70">
              {step_guidance(@onboarding_state.current_step)}
            </p>
            <p
              :if={@onboarding_state.current_step[:evidence]}
              class="mt-2 text-xs text-base-content/70"
            >
              Evidence: {@onboarding_state.current_step.evidence}
            </p>
            <p
              :if={@onboarding_state.current_step[:next_command]}
              class="mt-1 text-xs text-base-content/70"
            >
              Next: <code>{@onboarding_state.current_step.next_command}</code>
            </p>

            <div
              :if={model_profile_step?(@onboarding_state.current_step)}
              class="mt-3 flex flex-wrap gap-2"
            >
              <button
                :for={profile <- model_profiles(@onboarding_state)}
                id={"onboarding-use-model-#{profile.name}"}
                type="button"
                phx-click="use_model_profile"
                phx-target={@myself}
                phx-value-profile={profile.name}
                class={button_class!("secondary")}
              >
                {"Use #{profile.name}"}
              </button>
            </div>

            <div
              :if={@onboarding_state.current_step.key == "run_doctor"}
              class="mt-3 flex flex-wrap gap-2"
            >
              <button
                id="onboarding-doctor-active-profile"
                type="button"
                phx-click="doctor_model_profile"
                phx-target={@myself}
                class={button_class!("secondary")}
              >
                Doctor active profile
              </button>
            </div>

            <div
              :if={@onboarding_state.current_step.key == "toggle_model_assisted_intent"}
              class="mt-3 flex flex-wrap gap-2"
            >
              <button
                id="onboarding-enable-model-assist"
                type="button"
                phx-click="set_model_assist"
                phx-target={@myself}
                phx-value-enabled="true"
                class={button_class!("secondary")}
              >
                Enable
              </button>
              <button
                id="onboarding-disable-model-assist"
                type="button"
                phx-click="set_model_assist"
                phx-target={@myself}
                phx-value-enabled="false"
                class={button_class!("secondary")}
              >
                Keep off
              </button>
            </div>

            <div
              :if={@onboarding_state.current_step.key == "optional_channel_registration"}
              class="mt-3 flex flex-wrap gap-2"
            >
              <button
                id="onboarding-channel-telegram"
                type="button"
                phx-click="channel_choice"
                phx-target={@myself}
                phx-value-choice="telegram"
                phx-value-step-id={@onboarding_state.current_step.id}
                class={button_class!("secondary")}
              >
                Telegram
              </button>
              <button
                id="onboarding-channel-email"
                type="button"
                phx-click="channel_choice"
                phx-target={@myself}
                phx-value-choice="email"
                phx-value-step-id={@onboarding_state.current_step.id}
                class={button_class!("secondary")}
              >
                Email
              </button>
              <button
                id="onboarding-channel-none"
                type="button"
                phx-click="channel_choice"
                phx-target={@myself}
                phx-value-choice="none"
                phx-value-step-id={@onboarding_state.current_step.id}
                class={button_class!("secondary")}
              >
                Skip
              </button>
              <button
                id="onboarding-channel-configured"
                type="button"
                phx-click="complete_step"
                phx-target={@myself}
                phx-value-step-id={@onboarding_state.current_step.id}
                class={button_class!("primary")}
              >
                Configured
              </button>
            </div>

            <div
              :if={@onboarding_state.current_step.key != "optional_channel_registration"}
              class="mt-3 flex flex-wrap gap-2"
            >
              <button
                id={"complete-onboarding-step-#{@onboarding_state.current_step.key}"}
                type="button"
                phx-click="complete_step"
                phx-target={@myself}
                phx-value-step-id={@onboarding_state.current_step.id}
                class={button_class!("primary")}
              >
                Complete
              </button>
              <button
                :if={@onboarding_state.current_step.optional?}
                id={"skip-onboarding-step-#{@onboarding_state.current_step.key}"}
                type="button"
                phx-click="skip_step"
                phx-target={@myself}
                phx-value-step-id={@onboarding_state.current_step.id}
                class={button_class!("secondary")}
              >
                Skip
              </button>
            </div>
          </div>
        </section>

        <section class="space-y-2">
          <div
            :for={step <- @onboarding_state.steps}
            id={"onboarding-step-#{step.key}"}
            class="rounded border border-base-300 p-3 text-sm"
            data-status={step.status}
            data-current={bool_string(current_step?(step, @onboarding_state.current_step))}
          >
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0 font-medium">{step.index}. {step.title}</div>
              <div class="shrink-0 whitespace-nowrap text-xs text-base-content/60">{step.status}</div>
            </div>
            <div class="text-xs text-base-content/60">
              {step.key}{optional_label(step)}
            </div>
          </div>
        </section>
      </div>
    </article>
    """
  end

  defp refresh_state(socket) do
    context = Map.get(socket.assigns, :renderer_context, %{})

    socket = assign(socket, :onboarding_wizard, OnboardingContext.wizard_state())

    case OnboardingContext.frame_or_resume(user_id(context), %{
           channel: :live_view,
           thread_id: field(context, :thread_id),
           session_id: field(context, :session_id)
         }) do
      {:ok, state} ->
        socket
        |> assign(:onboarding_state, state)
        |> assign(:onboarding_error, nil)

      {:error, reason} ->
        socket
        |> assign(:onboarding_state, nil)
        |> assign(:onboarding_error, reason)
    end
  end

  defp readiness_label(readiness), do: Map.get(@readiness_copy, readiness, "Unknown")

  defp wizard_track("advanced"), do: :advanced
  defp wizard_track(_quickstart), do: :quickstart

  defp wizard_step_label(step) do
    step
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp record_step(socket, step_id, outcome, note) do
    state = socket.assigns.onboarding_state

    params = %{
      objective_id: state.objective.id,
      step_id: step_id,
      outcome: outcome,
      note: note,
      evidence: current_step_evidence(socket, step_id)
    }

    case run_action("onboarding_step_complete", params, action_context(socket)) do
      {:ok, %{status: :completed} = response} ->
        socket
        |> assign(:onboarding_state, response_state(response))
        |> assign(:onboarding_notice, "Onboarding progress recorded.")
        |> assign(:onboarding_error, nil)

      {:ok, response} ->
        socket
        |> assign(:onboarding_notice, "")
        |> assign(:onboarding_error, Map.get(response, :error) || response_text(response))

      {:error, reason} ->
        socket
        |> assign(:onboarding_notice, "")
        |> assign(:onboarding_error, reason)
    end
  end

  defp record_current_step(socket, outcome, note) do
    case socket.assigns.onboarding_state.current_step do
      %{id: step_id} -> record_step(socket, step_id, outcome, note)
      _other -> socket
    end
  end

  defp put_flash_notice(socket, notice), do: assign(socket, :onboarding_notice, notice)

  defp response_error(response), do: ErrorExtraction.from_response(response)

  defp current_step_evidence(socket, step_id) do
    socket.assigns.onboarding_state.steps
    |> Enum.find(&(&1.id == step_id))
    |> case do
      %{evidence: evidence} -> evidence
      _other -> nil
    end
  end

  defp response_state(response) do
    %{
      objective: response.objective,
      steps: response.steps,
      current_step: response.current_step,
      evidence: Map.get(response, :evidence, %{}),
      created?: false
    }
  end

  defp run_action(name, params, context), do: apply(Runner, :run, [name, params, context])

  defp button_class!(variant), do: Patterns.compact_button_class!(variant)

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

  defp step_guidance(%{key: "welcome_scope"}) do
    "Review the setup scope before recording progress."
  end

  defp step_guidance(%{key: "resolve_credential_or_endpoint"}) do
    "Remote credentials use the Settings Central secret form; local endpoints are checked by the model doctor."
  end

  defp step_guidance(%{key: "run_doctor"}) do
    "Use `mix allbert.model doctor PROFILE` or the Settings Central model doctor."
  end

  defp step_guidance(%{key: "pick_model_profile"}) do
    "Use `mix allbert.model use PROFILE` or the Settings Central model picker."
  end

  defp step_guidance(%{key: "toggle_model_assisted_intent"}) do
    "Use `mix allbert.model use PROFILE --enable-assist` or update `intent.model_assist_enabled`."
  end

  defp step_guidance(%{key: "optional_channel_registration"}) do
    "Use `mix allbert.channels telegram set-token TOKEN` or `mix allbert.channels email set-password --type imap|smtp PASSWORD`, then record the choice here."
  end

  defp step_guidance(%{key: "identity_slot_preview"}) do
    "Review the identity root, kept identity count, Active Memory flag, and direct-answer model flag. Try `mix allbert.memory retrieve --query \"concise release reports\"`; this step writes no identity memory."
  end

  defp step_guidance(%{key: "done"}), do: "Record completion when onboarding is ready to close."
  defp step_guidance(_step), do: "Record this step when the setup action is complete."

  defp model_profile_step?(%{key: key})
       when key in ["pick_provider_profile", "pick_model_profile"],
       do: true

  defp model_profile_step?(_step), do: false

  defp model_profiles(%{evidence: %{model_profiles: profiles}}) when is_list(profiles),
    do: profiles

  defp model_profiles(_state), do: []

  defp active_model_profile(socket) do
    get_in(socket.assigns, [:onboarding_state, :evidence, :active_model_profile]) || "local"
  end

  defp current_step?(_step, nil), do: false
  defp current_step?(step, current_step), do: step.id == current_step.id

  defp bool_string(true), do: "true"
  defp bool_string(false), do: "false"

  defp optional_label(%{optional?: true}), do: " optional"
  defp optional_label(_step), do: ""

  defp user_id(context), do: field(context, :user_id) || "local"

  defp response_text(response) do
    SurfaceRenderer.response_text(response, %{payload: :surface_payload})
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil
end
