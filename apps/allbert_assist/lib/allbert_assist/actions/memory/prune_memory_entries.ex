defmodule AllbertAssist.Actions.Memory.PruneMemoryEntries do
  @moduledoc "Finds and archives memory prune candidates."

  use AllbertAssist.Action,
    registry_order: 175,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :memory_archive,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "prune_memory_entries",
    description: "Dry-run or confirm archival of prune-nominated markdown memory entries.",
    category: "memory",
    tags: ["memory", "prune", "confirmation"],
    schema: [
      user_id: [type: :string, required: false],
      category: [type: :string, required: false],
      write: [type: :boolean, required: false],
      targets: [type: {:list, :map}, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      candidates: [type: {:list, :map}, required: true],
      confirmation_id: [type: :string, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.ClaimLifecycle
  alias AllbertAssist.Memory.Review
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:memory_write, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Context.user_id(params, context) do
      dispatch(params, user_id, context, permission_decision)
    else
      {:allowed, false} -> denied(permission_decision)
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  defp dispatch(params, user_id, context, permission_decision) do
    cond do
      approval_resume?(context) ->
        archive_approved_targets(params, user_id, permission_decision)

      truthy?(value(params, :write)) ->
        with_candidates(params, user_id, permission_decision, fn candidates ->
          maybe_confirm(candidates, user_id, context, permission_decision)
        end)

      true ->
        with_candidates(params, user_id, permission_decision, fn candidates ->
          dry_run(candidates, user_id, permission_decision)
        end)
    end
  end

  defp with_candidates(params, user_id, permission_decision, fun) do
    case candidates(params, user_id) do
      {:ok, candidates} -> fun.(candidates)
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  defp candidates(params, user_id) do
    retention_policy = settings_value("memory.retention_policy", "preserve_markdown")
    max_entries = settings_value("memory.max_entries_per_category", 500)

    with {:ok, candidates} <-
           Review.prune_candidates(Memory.root(),
             category: value(params, :category),
             max_entries_per_category: max_entries,
             retention_policy: retention_policy
           ) do
      {:ok, Enum.filter(candidates, &candidate_for_user?(&1, user_id))}
    end
  end

  defp dry_run(candidates, user_id, permission_decision) do
    {:ok,
     %{
       message: "Found #{length(candidates)} memory prune candidate(s).",
       status: :completed,
       permission_decision: permission_decision,
       candidates: candidates,
       actions: [
         %{
           name: "prune_memory_entries",
           status: :completed,
           permission: :memory_write,
           permission_decision: permission_decision,
           execution: :dry_run,
           user_id: user_id,
           candidate_count: length(candidates)
         }
       ]
     }}
  end

  defp maybe_confirm([], user_id, _context, permission_decision) do
    dry_run([], user_id, permission_decision)
  end

  defp maybe_confirm(candidates, user_id, context, permission_decision) do
    with {:ok, targets} <- lifecycle_targets(candidates, user_id) do
      if confirmation_required?() do
        create_confirmation(candidates, targets, user_id, context, permission_decision)
      else
        archive_targets(candidates, targets, user_id, permission_decision)
      end
    else
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  defp archive_approved_targets(params, user_id, permission_decision) do
    targets = value(params, :targets)

    if is_list(targets) and targets != [] do
      candidates = Enum.map(targets, &target_candidate/1)
      archive_targets(candidates, targets, user_id, permission_decision)
    else
      error(permission_decision, :missing_prune_targets)
    end
  end

  defp archive_targets(candidates, targets, user_id, permission_decision) do
    case Enum.reduce_while(targets, {:ok, []}, &archive_target(&1, user_id, &2)) do
      {:ok, reversed} ->
        archived = Enum.reverse(reversed)

        {:ok,
         %{
           message: "Archived #{length(archived)} memory prune candidate(s).",
           status: :completed,
           permission_decision: permission_decision,
           candidates: candidates,
           archived: archived,
           actions: [
             %{
               name: "prune_memory_entries",
               status: :completed,
               permission: :memory_write,
               permission_decision: permission_decision,
               execution: :archive,
               user_id: user_id,
               archived_count: length(archived)
             }
           ]
         }}

      {:error, reason, _partial} ->
        error(permission_decision, reason)
    end
  end

  defp create_confirmation(candidates, targets, user_id, context, permission_decision) do
    case Confirmations.create(
           %{
             origin: origin(context, user_id),
             target_action: %{name: "prune_memory_entries", module: inspect(__MODULE__)},
             target_permission: :memory_write,
             target_execution_mode: :memory_archive,
             security_decision: permission_decision,
             params_summary: %{
               user_id: user_id,
               candidate_count: length(candidates),
               paths: Enum.map(candidates, & &1.path)
             },
             resume_params_ref: %{user_id: user_id, write: true, targets: targets}
           },
           context
         ) do
      {:ok, confirmation} ->
        {:ok,
         response_needs_confirmation(
           "Memory prune is ready for approval. Confirmation request: #{confirmation["id"]}. No files were moved.",
           %{
             permission_decision: permission_decision,
             candidates: candidates,
             confirmation: confirmation,
             confirmation_id: confirmation["id"],
             actions: [
               %{
                 name: "prune_memory_entries",
                 status: :needs_confirmation,
                 permission: :memory_write,
                 permission_decision: permission_decision,
                 execution: :pending_confirmation,
                 confirmation_id: confirmation["id"],
                 user_id: user_id,
                 candidate_count: length(candidates)
               }
             ]
           }
         )}

      {:error, reason} ->
        error(permission_decision, reason)
    end
  end

  defp denied(permission_decision) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       candidates: [],
       actions: [action(:denied, permission_decision, nil)]
     }}
  end

  defp error(permission_decision, reason) do
    {:ok,
     %{
       message: "Unable to prune memory entries: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       candidates: [],
       actions: [action(:error, permission_decision, reason)]
     }}
  end

  defp action(status, permission_decision, error) do
    %{
      name: "prune_memory_entries",
      status: status,
      permission: :memory_write,
      permission_decision: permission_decision,
      error: error
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp candidate_for_user?(candidate, user_id) do
    case Memory.read_entry(candidate.path, user_id: user_id) do
      {:ok, _entry} -> true
      {:error, _reason} -> false
    end
  end

  defp lifecycle_targets(candidates, user_id) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, acc} ->
      case ClaimLifecycle.preview_path(candidate.path, user_id) do
        {:ok, preview} ->
          ids = ClaimLifecycle.new_ids()

          target = %{
            path: preview.path,
            claim_id: preview.claim_id,
            expected_tail_digest: preview.expected_tail_digest,
            reason: to_string(candidate.reason),
            revision_id: ids.revision_id,
            transition_id: ids.transition_id
          }

          {:cont, {:ok, [target | acc]}}

        {:error, reason} ->
          {:halt, {:error, {candidate.path, reason}}}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.reverse(targets)}
      error -> error
    end
  end

  defp archive_target(target, user_id, {:ok, acc}) do
    path = map_value(target, :path)

    with {:ok, preview} <- ClaimLifecycle.preview_path(path, user_id),
         :ok <- target_binding(preview, target),
         {:ok, archived} <-
           ClaimLifecycle.transition(
             preview,
             target_operation(map_value(target, :reason)),
             user_id,
             target
           ) do
      {:cont, {:ok, [archived | acc]}}
    else
      {:error, reason} -> {:halt, {:error, {path, reason}, Enum.reverse(acc)}}
    end
  end

  defp target_binding(preview, target) do
    if preview.claim_id == map_value(target, :claim_id) and
         preview.expected_tail_digest == map_value(target, :expected_tail_digest),
       do: :ok,
       else: {:error, :stale_prune_candidate}
  end

  defp target_operation("prune_nominated"), do: :archive_nominated
  defp target_operation(_reason), do: :archive

  defp target_candidate(target) do
    %{
      path: map_value(target, :path),
      reason: target |> map_value(:reason) |> String.to_existing_atom()
    }
  rescue
    ArgumentError -> %{path: map_value(target, :path), reason: :retention_policy}
  end

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp settings_value(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  end

  defp confirmation_required? do
    case Settings.get("memory.prune_requires_confirmation") do
      {:ok, false} -> false
      _other -> true
    end
  end

  defp approval_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approval_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approval_resume?(_context), do: false

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp value(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

  defp origin(context, user_id) do
    %{
      channel: Map.get(context, :channel, :unknown),
      actor: Map.get(context, :actor, user_id),
      user_id: user_id,
      session_id: Map.get(context, :session_id),
      surface: Map.get(context, :surface, "action")
    }
  end
end
