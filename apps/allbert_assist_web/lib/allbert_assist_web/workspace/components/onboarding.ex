defmodule AllbertAssistWeb.Workspace.Components.Onboarding do
  @moduledoc """
  First-run onboarding workspace panel.
  """

  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Onboarding, as: OnboardingContext

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:onboarding_notice, fn -> "" end)
      |> assign_new(:onboarding_error, fn -> nil end)

    {:ok, refresh_state(socket)}
  end

  @impl true
  def handle_event("complete_step", %{"step-id" => step_id}, socket) do
    {:noreply, record_step(socket, step_id, "completed", "Workspace onboarding step completed.")}
  end

  def handle_event("skip_step", %{"step-id" => step_id}, socket) do
    {:noreply, record_step(socket, step_id, "skipped", "Workspace onboarding step skipped.")}
  end

  def handle_event("channel_choice", %{"choice" => choice, "step-id" => step_id}, socket) do
    {outcome, note} =
      case choice do
        "none" -> {"skipped", "Operator skipped channel registration."}
        "telegram" -> {"completed", "Operator selected Telegram channel registration."}
        "email" -> {"completed", "Operator selected email channel registration."}
        _choice -> {"skipped", "Operator skipped channel registration."}
      end

    {:noreply, record_step(socket, step_id, outcome, note)}
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
                class="btn btn-secondary btn-sm"
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
                class="btn btn-secondary btn-sm"
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
                class="btn btn-outline btn-sm"
              >
                Skip
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
                class="btn btn-primary btn-sm"
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
                class="btn btn-outline btn-sm"
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
            <div class="flex flex-col gap-1 md:flex-row md:items-center md:justify-between">
              <div class="font-medium">{step.index}. {step.title}</div>
              <div class="text-xs text-base-content/60">{step.status}</div>
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

  defp record_step(socket, step_id, outcome, note) do
    state = socket.assigns.onboarding_state
    params = %{objective_id: state.objective.id, step_id: step_id, outcome: outcome, note: note}

    case Runner.run("onboarding_step_complete", params, action_context(socket)) do
      {:ok, %{status: :completed} = response} ->
        socket
        |> assign(:onboarding_state, response_state(response))
        |> assign(:onboarding_notice, "Onboarding progress recorded.")
        |> assign(:onboarding_error, nil)

      {:ok, response} ->
        socket
        |> assign(:onboarding_notice, "")
        |> assign(:onboarding_error, Map.get(response, :error) || response.message)
    end
  end

  defp response_state(response) do
    %{
      objective: response.objective,
      steps: response.steps,
      current_step: response.current_step,
      created?: false
    }
  end

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
    "Identity slot and Active Memory arrive in v0.39b. See `docs/operator/active-memory.md`; this step writes no identity memory."
  end

  defp step_guidance(%{key: "done"}), do: "Record completion when onboarding is ready to close."
  defp step_guidance(_step), do: "Record this step when the setup action is complete."

  defp current_step?(_step, nil), do: false
  defp current_step?(step, current_step), do: step.id == current_step.id

  defp bool_string(true), do: "true"
  defp bool_string(false), do: "false"

  defp optional_label(%{optional?: true}), do: " optional"
  defp optional_label(_step), do: ""

  defp user_id(context), do: field(context, :user_id) || "local"

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil
end
