defmodule AllbertAssist.Drafts.Promotion do
  @moduledoc """
  Live promotion helpers for reviewed non-code drafts.

  These helpers are called only from registered confirmation-gated actions.
  Draft metadata and YAML never grant authority by themselves.
  """

  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Claims.Format
  alias AllbertAssist.Memory.ProjectionSync
  alias AllbertAssist.Objectives
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.YamlCodec
  alias AllbertAssist.Skills
  alias AllbertAssist.Workflows.Validator

  @type skill_target :: %{
          required(:name) => String.t(),
          required(:path) => String.t(),
          required(:skill_md_path) => String.t()
        }
  @type workflow_target :: %{required(:path) => String.t()}

  @doc "Promote an instruction-only skill draft to the local skills root."
  @spec promote_skill(String.t(), map()) ::
          {:ok,
           %{
             required(:draft) => Store.non_code_draft_summary(),
             required(:skill) => skill_target(),
             required(:result) => skill_target()
           }}
          | {:error, term()}
  def promote_skill(id, context \\ %{}) when is_binary(id) and is_map(context) do
    with {:ok, draft} <- Store.show_draft(id, kind: "skill"),
         :ok <- require_promotable(draft),
         payload <- Map.fetch!(draft, :payload),
         {:ok, skill} <- write_skill(payload, context),
         {:ok, promoted} <-
           Store.promote_draft(id,
             kind: "skill",
             promotion: %{target: "skill", path: skill.skill_md_path, promoted_by: actor(context)}
           ) do
      {:ok, %{draft: promoted, skill: skill, result: skill}}
    end
  end

  @doc "Promote a workflow draft to the live workflows root."
  @spec promote_workflow(String.t(), map()) ::
          {:ok,
           %{
             required(:draft) => map(),
             required(:workflow) => map(),
             required(:path) => String.t(),
             required(:result) => workflow_target()
           }}
          | {:error, term()}
  def promote_workflow(id, context \\ %{}) when is_binary(id) and is_map(context) do
    with {:ok, draft} <- Store.show_draft(id, kind: "workflow"),
         :ok <- require_promotable(draft),
         %{"workflow" => workflow} <- Map.fetch!(draft, :payload),
         {:ok, workflow} <- Validator.validate(workflow),
         {:ok, path} <- write_workflow(workflow),
         {:ok, promoted} <-
           Store.promote_draft(id,
             kind: "workflow",
             promotion: %{target: "workflow", path: path, promoted_by: actor(context)}
           ) do
      {:ok, %{draft: promoted, workflow: workflow, path: path, result: %{path: path}}}
    else
      :error -> {:error, :workflow_payload_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Return the exact content binding placed into a legacy Memory confirmation."
  def memory_draft_binding(id) when is_binary(id) do
    with {:ok, draft} <- show_memory_draft(id),
         :ok <- require_promotable(draft),
         {:ok, digest} <- memory_draft_digest(draft) do
      {:ok, %{id: id, draft_digest: digest}}
    end
  end

  @doc "Promote a legacy Memory draft through the canonical claim writer."
  @spec promote_memory(String.t(), map()) ::
          {:ok,
           %{
             required(:draft) => map(),
             required(:memory) => map(),
             required(:result) => map()
           }}
          | {:error, term()}
  def promote_memory(id, context \\ %{}) when is_binary(id) and is_map(context) do
    with {:ok, binding} <- memory_draft_binding(id) do
      promote_memory(id, binding.draft_digest, context)
    end
  end

  @doc "Promote only the exact draft digest bound into the operator confirmation."
  def promote_memory(id, expected_digest, context)
      when is_binary(id) and is_binary(expected_digest) and is_map(context) do
    with {:ok, draft} <- show_memory_draft(id),
         :ok <- require_promotable(draft),
         {:ok, actual_digest} <- memory_draft_digest(draft),
         :ok <- exact_draft_digest(expected_digest, actual_digest),
         %{"memory" => memory} <- Map.fetch!(draft, :payload),
         {:ok, target} <- memory_target(draft, memory),
         {:ok, binding} <- memory_transition_binding(draft, target, actual_digest, context),
         {:ok, _bound} <- Store.bind_memory_promotion(id, draft.kind, binding),
         {:ok, append} <-
           Claims.append(
             target.claim_id,
             target.expected_tail_digest,
             transition(draft, memory, binding)
           ),
         outcome <- memory_outcome(append),
         # v1.3 M9.b.12.a. Promotion appends a canonical claim, so the
         # projection must advance with it; otherwise the promoted claim is
         # unretrievable until a full rebuild.
         outcome <- Map.put(outcome, :projection, ProjectionSync.refresh(append.claim_id)),
         {:ok, promoted} <- Store.complete_memory_promotion(id, draft.kind, outcome) do
      result = Map.put(outcome, :path, append.path)
      {:ok, %{draft: promoted, memory: result, result: result}}
    else
      :error -> {:error, :memory_payload_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Finish content scrubbing only for legacy drafts whose bound claim transition committed."
  def reconcile_memory_drafts do
    items =
      Store.list_drafts()
      |> Enum.filter(&(&1.kind in ["memory_promotion", "memory_update"]))
      |> Enum.filter(&is_map(&1.promotion_pending))
      |> Enum.map(&reconcile_memory_draft/1)

    {:ok,
     %{
       attempted_count: length(items),
       completed_count: Enum.count(items, &(&1.outcome == "content_scrubbed")),
       pending_count: Enum.count(items, &(&1.outcome == "awaiting_operator_retry")),
       retryable_error_count: Enum.count(items, &(&1.outcome == "retryable_error")),
       items: items
     }}
  end

  @doc "Promote an objective draft by framing it through the v0.24 objective facade."
  @spec promote_objective(String.t(), map()) ::
          {:ok,
           %{
             required(:draft) => map(),
             required(:objective) => map(),
             required(:result) => map()
           }}
          | {:error, term()}
  def promote_objective(id, context \\ %{}) when is_binary(id) and is_map(context) do
    with {:ok, draft} <- Store.show_draft(id, kind: "objective"),
         :ok <- require_promotable(draft),
         %{"objective" => objective_input} <- Map.fetch!(draft, :payload),
         {:ok, %{objective: objective}} <-
           Objectives.frame(frame_input(objective_input, context), context),
         result <- objective_result(objective, context),
         {:ok, promoted} <-
           Store.promote_draft(id,
             kind: "objective",
             promotion: result
           ) do
      {:ok,
       %{draft: promoted, objective: Objectives.objective_summary(objective), result: result}}
    else
      :error -> {:error, :objective_payload_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp show_memory_draft(id) do
    case Store.show_draft(id, kind: "memory_promotion") do
      {:ok, draft} -> {:ok, draft}
      {:error, _reason} -> Store.show_draft(id, kind: "memory_update")
    end
  end

  defp require_promotable(%{tier: "draft", live_authority: false}), do: :ok
  defp require_promotable(%{tier: tier}), do: {:error, {:draft_not_promotable, tier}}
  defp require_promotable(_draft), do: {:error, :invalid_draft}

  defp write_skill(payload, context) do
    name = payload |> Map.get("name", Map.fetch!(payload, "id")) |> Skills.normalize_name()
    root = Path.join(Paths.skills_root(), name)
    skill_md_path = Path.join(root, "SKILL.md")

    if File.exists?(skill_md_path) do
      {:error, {:skill_exists, name}}
    else
      with :ok <- File.mkdir_p(root),
           :ok <- File.write(skill_md_path, skill_markdown(payload, name, context)) do
        {:ok, %{name: name, path: root, skill_md_path: skill_md_path}}
      end
    end
  end

  defp write_workflow(%{"id" => id} = workflow) when is_binary(id) do
    path = Path.join([Paths.home(), "workflows", id <> ".yaml"])

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, YamlCodec.encode!(workflow)) do
      {:ok, path}
    end
  end

  defp write_workflow(_workflow), do: {:error, :workflow_id_required}

  defp memory_draft_digest(draft) do
    with {:ok, artifact} <- File.read(draft.artifact_path) do
      {:ok,
       digest(
         Format.canonical_json(%{
           "schema_version" => 1,
           "id" => draft.id,
           "kind" => draft.kind,
           "payload" => draft.payload,
           "artifact_digest" => digest(artifact)
         })
       )}
    else
      {:error, reason} -> {:error, {:memory_draft_artifact_unavailable, reason}}
    end
  end

  defp exact_draft_digest(digest, digest), do: :ok
  defp exact_draft_digest(_expected, _actual), do: {:error, :memory_draft_digest_changed}

  defp memory_target(%{promotion_pending: %{} = pending}, _memory) do
    {:ok,
     %{
       claim_id: pending["claim_id"],
       expected_tail_digest: pending["expected_tail_digest"],
       legacy_path: pending["legacy_path"],
       legacy_digest: pending["legacy_digest"]
     }}
  end

  defp memory_target(%{kind: "memory_update"}, %{"path" => path})
       when is_binary(path) and path != "" do
    with {:ok, identity} <- Claims.legacy_identity(path),
         {:ok, stream} <- Claims.read(identity.claim_id) do
      {:ok,
       %{
         claim_id: identity.claim_id,
         expected_tail_digest: stream.tail_digest,
         legacy_path: identity.path,
         legacy_digest: identity.digest
       }}
    end
  end

  defp memory_target(%{kind: "memory_update"}, _memory),
    do: {:error, :memory_update_path_required}

  defp memory_target(draft, _memory) do
    {:ok,
     %{
       claim_id: deterministic_uuid("claim", "#{draft.kind}\0#{draft.id}"),
       expected_tail_digest: nil,
       legacy_path: nil,
       legacy_digest: nil
     }}
  end

  defp memory_transition_binding(%{promotion_pending: %{} = pending}, _target, _digest, context) do
    if pending["actor"] == actor(context) do
      {:ok,
       %{
         schema_version: pending["schema_version"],
         draft_digest: pending["draft_digest"],
         claim_id: pending["claim_id"],
         expected_tail_digest: pending["expected_tail_digest"],
         legacy_path: pending["legacy_path"],
         legacy_digest: pending["legacy_digest"],
         actor: pending["actor"],
         recorded_at: pending["recorded_at"],
         transition_id: pending["transition_id"],
         revision_id: pending["revision_id"]
       }}
    else
      {:error, :memory_promotion_actor_changed}
    end
  end

  defp memory_transition_binding(draft, target, draft_digest, context) do
    actor = actor(context)

    transition_seed =
      Format.canonical_json(%{
        draft_digest: draft_digest,
        actor: actor,
        claim_id: target.claim_id
      })

    transition_id = deterministic_uuid("transition", transition_seed)

    {:ok,
     %{
       schema_version: 1,
       draft_digest: draft_digest,
       claim_id: target.claim_id,
       expected_tail_digest: target.expected_tail_digest,
       legacy_path: target.legacy_path,
       legacy_digest: target.legacy_digest,
       actor: actor,
       recorded_at: draft.updated_at,
       transition_id: transition_id,
       revision_id: deterministic_uuid("revision", transition_id)
     }}
  end

  defp transition(draft, memory, binding) do
    %{
      revision_id: binding.revision_id,
      transition_id: binding.transition_id,
      state: "kept",
      recorded_at: binding.recorded_at,
      valid_from: nil,
      valid_to: nil,
      actor: binding.actor,
      action: "legacy_confirmed_draft",
      category: Map.get(memory, "category", "notes"),
      operator_id: binding.actor,
      namespace: "default",
      value: Map.get(memory, "body", Map.get(memory, "summary")),
      summary: Map.get(memory, "summary"),
      authority_kind: "legacy_confirmed_draft",
      draft_id: draft.id,
      draft_kind: draft.kind,
      draft_digest: binding.draft_digest,
      legacy_path: binding.legacy_path,
      legacy_digest: binding.legacy_digest
    }
  end

  defp memory_outcome(append) do
    %{
      target: "memory_claim",
      claim_id: append.claim_id,
      revision_id: append.revision_id,
      transition_id: append.transition_id,
      append_outcome: Atom.to_string(append.outcome),
      content_scrubbed: true
    }
  end

  defp deterministic_uuid(domain, value) do
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> =
      :crypto.hash(:sha256, "allbert.memory.legacy-draft.#{domain}.v1\0" <> value)

    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x5000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    [hex(a, 8), hex(b, 4), hex(c, 4), hex(d, 4), hex(e, 12)]
    |> Enum.join("-")
  end

  defp hex(integer, width),
    do:
      integer
      |> Integer.to_string(16)
      |> String.downcase(:ascii)
      |> String.pad_leading(width, "0")

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp reconcile_memory_draft(draft) do
    pending = draft.promotion_pending

    case Claims.read(pending["claim_id"]) do
      {:ok, stream} -> reconcile_committed_memory_draft(draft, pending, stream.records)
      {:error, :not_found} -> recovery_item(draft, "awaiting_operator_retry")
      {:error, reason} -> recovery_item(draft, "retryable_error", reason)
    end
  end

  defp reconcile_committed_memory_draft(draft, pending, records) do
    case Enum.find(records, &(&1["transition_id"] == pending["transition_id"])) do
      %{} = record -> complete_recovered_memory_draft(draft, pending, record)
      nil -> recovery_item(draft, "awaiting_operator_retry")
    end
  end

  defp complete_recovered_memory_draft(draft, pending, record) do
    valid? =
      record["action"] == "legacy_confirmed_draft" and
        get_in(record, ["payload", "draft_digest"]) == pending["draft_digest"]

    if valid? do
      outcome = %{
        target: "memory_claim",
        claim_id: pending["claim_id"],
        revision_id: record["revision_id"],
        transition_id: record["transition_id"],
        append_outcome: "recovered",
        content_scrubbed: true
      }

      case Store.complete_memory_promotion(draft.id, draft.kind, outcome) do
        {:ok, _terminal} -> recovery_item(draft, "content_scrubbed")
        {:error, reason} -> recovery_item(draft, "retryable_error", reason)
      end
    else
      recovery_item(draft, "retryable_error", :legacy_draft_transition_mismatch)
    end
  end

  defp recovery_item(draft, outcome, reason \\ nil) do
    %{draft_id: draft.id, kind: draft.kind, outcome: outcome}
    |> put_if_present(:reason, if(reason, do: inspect(reason)))
  end

  defp frame_input(objective_input, context) when is_map(objective_input) do
    objective_input
    |> normalize_objective_constraints()
    |> Map.put_new("user_id", actor(context))
    |> put_if_present("thread_id", Map.get(objective_input, "source_thread_id"))
    |> put_if_present("text", Map.get(objective_input, "objective"))
  end

  defp normalize_objective_constraints(%{"constraints" => constraints} = input)
       when constraints in [nil, "", %{}],
       do: Map.delete(input, "constraints")

  defp normalize_objective_constraints(%{"constraints" => constraints} = input)
       when is_map(constraints),
       do: Map.put(input, "constraints", Jason.encode!(constraints))

  defp normalize_objective_constraints(input), do: input

  defp objective_result(objective, context) do
    %{
      target: "objective",
      objective_id: objective.id,
      user_id: objective.user_id,
      title: objective.title,
      status: objective.status,
      promoted_by: actor(context)
    }
  end

  defp skill_markdown(payload, name, context) do
    description = Map.get(payload, "description", "Self-improvement skill #{name}.")
    instructions = Map.get(payload, "instructions", description)

    """
    ---
    name: #{name}
    description: #{description}
    compatibility: Allbert v0.47+ operator-confirmed instruction-only local skill.
    metadata:
      allbert.kind: instruction_only
      allbert.version: "0.47.1"
      allbert.source: self_improvement
      allbert.source_suggestion_id: #{Map.get(payload, "source_suggestion_id", "unknown")}
      allbert.promoted_by: #{actor(context)}
    ---

    ## Workflow

    #{instructions}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp actor(context) do
    Map.get(context, :operator_id) || Map.get(context, "operator_id") ||
      Map.get(context, :user_id) || Map.get(context, "user_id") ||
      Map.get(context, :actor) || Map.get(context, "actor") || "local"
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
