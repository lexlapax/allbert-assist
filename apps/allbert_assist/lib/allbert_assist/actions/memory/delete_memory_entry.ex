defmodule AllbertAssist.Actions.Memory.DeleteMemoryEntry do
  @moduledoc "Archives a Memory claim reversibly, usually after confirmation."

  use AllbertAssist.Action,
    registry_order: 174,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :memory_archive,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "delete_memory_entry",
    description: "Archive one markdown memory entry through the confirmation workflow.",
    category: "memory",
    tags: ["memory", "delete", "confirmation"],
    schema: [
      path: [type: :string, required: true],
      user_id: [type: :string, required: false],
      claim_id: [type: :string, required: false],
      expected_tail_digest: [type: :string, required: false],
      revision_id: [type: :string, required: false],
      transition_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      confirmation_id: [type: :string, required: false],
      archived: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory.ClaimLifecycle
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:memory_write, context)
    path = value(params, :path)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, path} <- required_path(path),
         {:ok, user_id} <- Context.user_id(params, context) do
      cond do
        approval_resume?(context) ->
          archive_now(params, path, user_id, permission_decision, :approval)

        confirmation_required?("memory.delete_requires_confirmation") ->
          create_confirmation(path, user_id, context, permission_decision)

        true ->
          archive_now(params, path, user_id, permission_decision, :immediate)
      end
    else
      {:allowed, false} -> denied(permission_decision)
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  def run(_params, context),
    do: error(PermissionGate.authorize(:memory_write, context), :missing_path)

  defp archive_now(params, path, user_id, permission_decision, execution) do
    ids = lifecycle_ids(params)

    with {:ok, preview} <- exact_preview(params, path, user_id),
         {:ok, archived} <- ClaimLifecycle.transition(preview, :archive, user_id, ids) do
      {:ok,
       %{
         message: "Archived memory claim reversibly: #{preview.summary}",
         status: :completed,
         permission_decision: permission_decision,
         archived: archived,
         actions: [
           %{
             name: "delete_memory_entry",
             status: :completed,
             permission: :memory_write,
             permission_decision: permission_decision,
             execution: execution,
             memory_path: archived.path,
             archived_path: archived.archived_path,
             claim_id: archived.claim_id,
             user_id: user_id
           }
         ]
       }}
    else
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  defp create_confirmation(path, user_id, context, permission_decision) do
    ids = ClaimLifecycle.new_ids()

    with {:ok, preview} <- ClaimLifecycle.preview_path(path, user_id),
         {:ok, confirmation} <-
           Confirmations.create(
             %{
               origin: origin(context, user_id),
               target_action: %{name: "delete_memory_entry", module: inspect(__MODULE__)},
               target_permission: :memory_write,
               target_execution_mode: :memory_archive,
               security_decision: permission_decision,
               params_summary: %{
                 path: preview.path,
                 category: preview.category,
                 summary: preview.summary,
                 claim_id: preview.claim_id,
                 expected_tail_digest: preview.expected_tail_digest,
                 user_id: user_id
               },
               resume_params_ref: %{
                 path: preview.path,
                 user_id: user_id,
                 claim_id: preview.claim_id,
                 expected_tail_digest: preview.expected_tail_digest,
                 revision_id: ids.revision_id,
                 transition_id: ids.transition_id
               }
             },
             context
           ) do
      {:ok,
       %{
         message:
           "Memory archive is ready for approval. Confirmation request: #{confirmation["id"]}. The claim remains active until approval.",
         status: :needs_confirmation,
         permission_decision: permission_decision,
         confirmation: confirmation,
         confirmation_id: confirmation["id"],
         actions: [
           %{
             name: "delete_memory_entry",
             status: :needs_confirmation,
             permission: :memory_write,
             permission_decision: permission_decision,
             execution: :pending_confirmation,
             confirmation_id: confirmation["id"],
             memory_path: preview.path,
             claim_id: preview.claim_id,
             user_id: user_id
           }
         ]
       }}
    else
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  defp exact_preview(params, path, user_id) do
    with {:ok, preview} <- ClaimLifecycle.preview_path(path, user_id),
         :ok <- exact_binding(preview, params) do
      {:ok, preview}
    end
  end

  defp exact_binding(preview, params) do
    claim_id = value(params, :claim_id)
    expected_tail = value(params, :expected_tail_digest)

    cond do
      is_binary(claim_id) and claim_id != preview.claim_id ->
        {:error, :claim_changed}

      is_binary(expected_tail) and expected_tail != preview.expected_tail_digest ->
        {:error, :stale_tail}

      true ->
        :ok
    end
  end

  defp lifecycle_ids(params) do
    case {value(params, :revision_id), value(params, :transition_id)} do
      {revision_id, transition_id} when is_binary(revision_id) and is_binary(transition_id) ->
        %{revision_id: revision_id, transition_id: transition_id}

      _other ->
        ClaimLifecycle.new_ids()
    end
  end

  defp denied(permission_decision) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, nil)]
     }}
  end

  defp error(permission_decision, reason) do
    {:ok,
     %{
       message: "Unable to delete memory entry: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:error, permission_decision, reason)]
     }}
  end

  defp action(status, permission_decision, error) do
    %{
      name: "delete_memory_entry",
      status: status,
      permission: :memory_write,
      permission_decision: permission_decision,
      error: error
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp confirmation_required?(key) do
    case Settings.get(key) do
      {:ok, false} -> false
      _other -> true
    end
  end

  defp approval_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approval_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approval_resume?(_context), do: false

  defp required_path(path) when is_binary(path) and path != "", do: {:ok, path}
  defp required_path(_path), do: {:error, :missing_path}

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
