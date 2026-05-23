defmodule AllbertAssist.Actions.Memory.PruneMemoryEntries do
  @moduledoc "Finds and archives memory prune candidates."

  use AllbertAssist.Action,
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
      write: [type: :boolean, required: false]
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
  alias AllbertAssist.Memory.Review
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:memory_write, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Context.user_id(params, context),
         {:ok, candidates} <- candidates(params, user_id) do
      cond do
        approval_resume?(context) ->
          archive_candidates(candidates, user_id, permission_decision)

        truthy?(value(params, :write)) ->
          maybe_confirm(candidates, user_id, context, permission_decision)

        true ->
          dry_run(candidates, user_id, permission_decision)
      end
    else
      {:allowed, false} -> denied(permission_decision)
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
    if confirmation_required?() do
      create_confirmation(candidates, user_id, context, permission_decision)
    else
      archive_candidates(candidates, user_id, permission_decision)
    end
  end

  defp archive_candidates(candidates, user_id, permission_decision) do
    paths = Enum.map(candidates, & &1.path)

    case Memory.archive_entries(paths, user_id: user_id) do
      {:ok, archived} ->
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

      {:error, reason} ->
        error(permission_decision, reason)
    end
  end

  defp create_confirmation(candidates, user_id, context, permission_decision) do
    case Confirmations.create(%{
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
           resume_params_ref: %{user_id: user_id, write: true}
         }) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message:
             "Memory prune is ready for approval. Confirmation request: #{confirmation["id"]}. No files were moved.",
           status: :needs_confirmation,
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
         }}

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
