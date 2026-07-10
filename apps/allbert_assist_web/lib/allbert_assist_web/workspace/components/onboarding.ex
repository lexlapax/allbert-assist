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
  # v0.64.3: the parent WorkspaceLive forwards each streamed pull-progress frame here
  # via `send_update(@myself, model_pull_frame: frame)`. Append and re-render without
  # re-running the full wizard-state recompute (which would reset transient state).
  def update(%{model_pull_frame: frame}, socket) do
    {:ok, assign(socket, :model_pull_progress, socket.assigns.model_pull_progress ++ [frame])}
  end

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
      |> assign_new(:model_pull_progress, fn -> [] end)
      |> assign_new(:model_pulling?, fn -> false end)
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

  def handle_event("install_runtime", _params, socket) do
    {:noreply,
     socket
     |> run_confirmed_onboarding_action(
       "install_ollama",
       %{},
       "Local runtime installation approved and started."
     )
     |> refresh_state()
     |> reprobe()}
  end

  def handle_event("pull_model", _params, socket) do
    context = action_context(socket)

    params =
      %{}
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

  # v0.64.3: finalize the async model pull started in `handle_event("pull_model", ...)`.
  # Streamed progress frames arrive separately via the targeted `update/2` clause.
  @impl true
  def handle_async(:pull_model, {:ok, {:ok, %{status: :completed} = response}}, socket) do
    {:noreply,
     socket
     |> assign(:model_pulling?, false)
     |> assign_action_success("Starter model pull approved and completed.", response)
     |> refresh_state()
     |> reprobe()}
  end

  def handle_async(:pull_model, {:ok, {:ok, response}}, socket) do
    {:noreply,
     socket
     |> assign(model_pulling?: false, onboarding_error: response_error(response))
     |> refresh_state()
     |> reprobe()}
  end

  def handle_async(:pull_model, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(model_pulling?: false, onboarding_error: reason)
     |> refresh_state()
     |> reprobe()}
  end

  def handle_async(:pull_model, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(model_pulling?: false, onboarding_error: "Model pull crashed: #{inspect(reason)}")
     |> refresh_state()
     |> reprobe()}
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
      <section id="workspace-model-path-repair" class="space-y-2">
        <p class="text-xs font-medium text-base-content/80">{@model_guidance.headline}</p>
        <p class="text-xs text-base-content/70">{@model_guidance.next_action}</p>

        <div class="flex flex-wrap gap-2">
          <button
            :if={@model_guidance.action == :install_runtime}
            type="button"
            id="workspace-model-install-runtime"
            class="btn btn-sm btn-primary"
            phx-click="install_runtime"
            phx-target={@myself}
          >
            Install local runtime
          </button>
          <button
            :if={@model_guidance.action == :pull_model}
            type="button"
            id="workspace-model-pull"
            class="btn btn-sm btn-primary"
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
            class="btn btn-sm btn-primary"
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
    |> assign(
      :model_guidance,
      OnboardingContext.model_guidance_for(wizard.readiness, wizard.track)
    )
    |> assign(:provider_profiles, provider_profiles())
    |> assign(:tier_line, tier_line())
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
