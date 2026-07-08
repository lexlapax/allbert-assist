defmodule AllbertAssist.Actions.Settings.ApplyPersonaProfile do
  @moduledoc """
  v0.63 M4 — apply a reviewed persona preset (ADR 0075, seed-only).

  Seeds a persona's `settings_seeds` into Settings Central over `@safe_write_keys`
  only, after an explicit review/confirm. Effectful, so `:settings_write` with
  `confirmation: :required`; `exposure: :internal` (setup-time, not an agent tool).

  The action writes **nothing** before an approved confirmation: `dry_run` and the
  `needs_confirmation` path both return the **review diff** (each seed key
  `current → proposed`, changed vs unchanged) plus the seed-only suggestions
  (apps/channels/intents highlight, never write) and `model_purpose_map` advice with
  any hosted-egress warning. Only an approved-confirmation resume performs the writes.
  It grants no authority, enables no egress, connects no channel, and stores no
  secret. `first_chat_prompts` are consumed later at the `first_chat` step, not here.
  """

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :settings_write,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "apply_persona_profile",
    description:
      "Apply a reviewed persona preset by seeding safe-write settings (confirmation-gated).",
    category: "settings",
    tags: ["settings", "persona", "onboarding", "write", "confirmation"],
    schema: [
      persona_id: [type: :string, required: true],
      dry_run: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      review: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Personas
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)
    persona_id = field(params, :persona_id)

    case Personas.fetch(to_string(persona_id)) do
      :error ->
        {:ok, denied(persona_id, permission_decision, {:unknown_persona, persona_id})}

      {:ok, persona} ->
        dispatch(persona, params, context, permission_decision)
    end
  end

  defp dispatch(persona, params, context, permission_decision) do
    cond do
      field(params, :dry_run) == true ->
        {:ok, preview(:completed, persona, permission_decision, executed: false)}

      approval_resume?(context) ->
        # M7.1: an approved resume must apply the *reviewed* persona. Reject if the
        # record's resume_params_ref persona_id was tampered to differ from the
        # persona_id the operator actually reviewed (params_summary).
        if reviewed_persona_matches?(persona, context) do
          apply_seeds(persona, context, permission_decision)
        else
          {:ok, denied(persona["persona_id"], permission_decision, :reviewed_persona_mismatch)}
        end

      PermissionGate.response_status(permission_decision) == :needs_confirmation ->
        request_confirmation(persona, context, permission_decision)

      PermissionGate.response_status(permission_decision) == :denied ->
        {:ok, denied(persona["persona_id"], permission_decision, :permission_denied)}

      # Fail closed: reaching :allowed means the confirmation floor did not apply,
      # i.e. this ran off the Runner without the action identity in context.
      true ->
        {:ok,
         denied(
           persona["persona_id"],
           permission_decision,
           :must_run_confirmation_gated
         )}
    end
  end

  # -- review diff (writes nothing) -------------------------------------------

  @doc false
  def build_review(persona) do
    seeds = Personas.settings_seeds(persona)

    changes =
      Enum.map(seeds, fn {key, proposed} ->
        current = current_value(key)

        %{
          key: key,
          current: current,
          proposed: proposed,
          changed?: current != proposed
        }
      end)

    %{
      persona_id: persona["persona_id"],
      label: persona["label"],
      changes: changes,
      change_count: Enum.count(changes, & &1.changed?),
      # Highlights only — these never write settings on apply.
      suggested_apps: Map.get(persona, "suggested_apps", []),
      suggested_channels: Map.get(persona, "suggested_channels", []),
      suggested_intents: Map.get(persona, "suggested_intents", []),
      model_purpose_map: Map.get(persona, "model_purpose_map", %{}),
      hosted_egress_warning:
        get_in(persona, ["model_purpose_map", "hosted_egress_warning"]) == true,
      first_chat_prompts: Map.get(persona, "first_chat_prompts", []),
      # Explicit authority statement — the persona grants none of these.
      grants: %{
        authority: false,
        egress: false,
        channel: false,
        secret: false,
        confirmation_floor_change: false
      }
    }
  end

  defp current_value(key) do
    case Settings.get(key) do
      {:ok, value} -> value
      _error -> nil
    end
  end

  # Defense in depth: never write a non-safe-write key, even if a bad catalog
  # slipped past boot validation.
  defp write_seed(key, value, action_context) do
    if Settings.safe_write_key?(key) do
      put_seed(key, value, action_context)
    else
      %{key: key, value: value, status: :skipped_not_safe_write}
    end
  end

  defp put_seed(key, value, action_context) do
    case Settings.put(key, value, action_context) do
      {:ok, resolved} -> %{key: key, value: resolved.value, status: :written}
      {:error, reason} -> %{key: key, value: value, status: :failed, error: inspect(reason)}
    end
  end

  # -- effectful apply (approved only) ----------------------------------------

  defp apply_seeds(persona, context, permission_decision) do
    action_context = action_context(context, permission_decision)

    results =
      Enum.map(Personas.settings_seeds(persona), fn {key, value} ->
        write_seed(key, value, action_context)
      end)

    failed? = Enum.any?(results, &(&1.status in [:failed, :skipped_not_safe_write]))
    status = if failed?, do: :error, else: :completed

    review = build_review(persona) |> Map.put(:writes, results) |> Map.put(:executed, true)

    {:ok,
     %{
       message: apply_message(persona, results, status),
       status: status,
       permission_decision: permission_decision,
       review: review,
       actions: [
         action(status, permission_decision, %{persona_id: persona["persona_id"], executed: true})
       ]
     }}
  end

  # -- confirmation (nothing written) -----------------------------------------

  defp request_confirmation(persona, context, permission_decision) do
    review = build_review(persona)

    {:ok, confirmation} =
      Confirmations.create(%{
        origin: origin(context),
        target_action: %{name: name(), module: inspect(__MODULE__)},
        target_permission: :settings_write,
        target_execution_mode: :settings_write,
        security_decision: permission_decision,
        # M7.4: carry the full per-key diff so `admin confirmations show` renders exactly
        # what will be seeded (current → proposed), not just a change count.
        params_summary: %{
          persona_id: persona["persona_id"],
          change_count: review.change_count,
          changes:
            Enum.map(review.changes, fn c ->
              %{key: c.key, current: inspect(c.current), proposed: inspect(c.proposed)}
            end)
        },
        resume_params_ref: %{persona_id: persona["persona_id"]}
      })

    {:ok,
     %{
       message:
         "Persona '#{persona["label"]}' is ready for review. Confirmation request: #{confirmation["id"]}. Nothing was written.",
       status: :needs_confirmation,
       permission_decision: permission_decision,
       review: Map.put(review, :executed, false),
       confirmation: confirmation,
       confirmation_id: confirmation["id"],
       actions: [
         action(:needs_confirmation, permission_decision, %{
           persona_id: persona["persona_id"],
           executed: false,
           confirmation_id: confirmation["id"]
         })
       ]
     }}
  end

  # -- rendering helpers ------------------------------------------------------

  defp preview(status, persona, permission_decision, executed: executed) do
    review = build_review(persona) |> Map.put(:executed, executed)

    %{
      message:
        "Persona '#{persona["label"]}' review: #{review.change_count} change(s) proposed. Nothing was written.",
      status: status,
      permission_decision: permission_decision,
      review: review,
      actions: [
        action(status, permission_decision, %{
          persona_id: persona["persona_id"],
          executed: executed
        })
      ]
    }
  end

  defp denied(persona_id, permission_decision, reason) do
    %{
      message: "I could not apply persona #{inspect(persona_id)}: #{inspect(reason)}",
      status: :denied,
      permission_decision: permission_decision,
      review: %{persona_id: persona_id, executed: false, error: reason},
      actions: [action(:denied, permission_decision, %{persona_id: persona_id, error: reason})]
    }
  end

  defp apply_message(persona, results, :completed),
    do: "Persona '#{persona["label"]}' applied: #{length(results)} setting(s) seeded."

  defp apply_message(persona, results, :error) do
    failed = Enum.filter(results, &(&1.status != :written))

    "Persona '#{persona["label"]}' partially applied; #{length(failed)} write(s) did not complete."
  end

  defp action(status, permission_decision, metadata) do
    Map.merge(
      %{
        name: name(),
        status: status,
        permission: :settings_write,
        permission_decision: permission_decision
      },
      metadata
    )
  end

  defp origin(context) do
    %{
      channel: Map.get(context, :channel, :unknown),
      actor: Map.get(context, :actor) || get_in(context, [:request, :operator_id]) || "local",
      surface: Map.get(context, :surface, "action")
    }
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp action_context(context, permission_decision) do
    request_context = Map.get(context, :request, context)

    request_context
    |> Map.take([:actor, :operator_id, :channel, :input_signal_id])
    |> Map.new(fn
      {:operator_id, value} -> {:actor, value}
      {:input_signal_id, value} -> {:source_signal_id, value}
      other -> other
    end)
    |> Map.put(:permission_decision, permission_decision)
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil

  # The persona being applied on resume must match the one the operator reviewed
  # (carried in the confirmation's params_summary). If the record carries no reviewed
  # persona_id we can't cross-check and allow (our own confirmations always carry it).
  defp reviewed_persona_matches?(persona, context) do
    reviewed = get_in(context, [:confirmation, :params_summary]) || %{}
    reviewed_id = field(reviewed, :persona_id)
    is_nil(reviewed_id) or reviewed_id == persona["persona_id"]
  end
end
