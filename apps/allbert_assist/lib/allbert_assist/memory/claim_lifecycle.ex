defmodule AllbertAssist.Memory.ClaimLifecycle do
  @moduledoc """
  Reversible lifecycle transitions for canonical Memory claims.

  This is a plain storage boundary, not a process: `Memory.Claims` remains the
  serialized append authority. Archive and restore preserve the Markdown
  stream and append a signed state transition; Forget is deliberately owned by
  `Memory.Forget` instead.
  """

  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Claims

  @actions %{
    archive: {"archived", "archive"},
    archive_nominated: {"archived", "archive_nominated"},
    restore: {"kept", "restore"}
  }

  @doc "Resolve one path into a claim and content-free lifecycle preview."
  def preview_path(path, user_id) when is_binary(path) and is_binary(user_id) do
    with {:ok, stream} <- Claims.read_path(path),
         {:ok, details} <- lifecycle_details(stream, user_id) do
      {:ok, Map.merge(details, stream_summary(stream))}
    end
  end

  def preview_path(_path, _user_id), do: {:error, :invalid_claim_path}

  @doc "Resolve one claim id into a content-free lifecycle preview."
  def preview(claim_id, user_id) when is_binary(claim_id) and is_binary(user_id) do
    with {:ok, stream} <- Claims.read(claim_id),
         {:ok, details} <- lifecycle_details(stream, user_id) do
      {:ok, Map.merge(details, stream_summary(stream))}
    end
  end

  def preview(_claim_id, _user_id), do: {:error, :invalid_claim_id}

  @doc "Append one exact archive, archive-nominated, or restore transition."
  def transition(preview, operation, actor, ids)
      when operation in [:archive, :archive_nominated, :restore] and is_map(preview) and
             is_map(ids) do
    with {:ok, actor} <- required_actor(actor),
         :ok <- valid_source_state(preview.state, operation),
         {:ok, revision_id} <- fetch_id(ids, :revision_id),
         {:ok, transition_id} <- fetch_id(ids, :transition_id),
         {state, action} <- Map.fetch!(@actions, operation),
         transition <-
           preview.payload
           |> Map.merge(%{
             "revision_id" => revision_id,
             "transition_id" => transition_id,
             "state" => state,
             "recorded_at" => now(),
             "actor" => actor,
             "action" => action
           })
           |> maybe_put_legacy(preview),
         {:ok, result} <-
           Claims.append(preview.claim_id, preview.expected_tail_digest, transition) do
      {:ok,
       Map.merge(result, %{
         state: String.to_existing_atom(state),
         operation: operation,
         archived_path: result.path
       })}
    end
  end

  def transition(_preview, _operation, _actor, _ids), do: {:error, :invalid_lifecycle_transition}

  @doc "Generate retry-stable revision and transition IDs for a confirmation receipt."
  def new_ids do
    %{revision_id: Ecto.UUID.generate(), transition_id: Ecto.UUID.generate()}
  end

  defp lifecycle_details(%{status: :grandfathered} = stream, user_id) do
    with {:ok, entry} <- Memory.read_entry(stream.path, user_id: user_id) do
      {:ok,
       %{
         category: to_string(entry.category),
         summary: entry.summary,
         state: "kept",
         payload: %{
           "value" => entry.body,
           "summary" => entry.summary,
           "category" => to_string(entry.category),
           "user_id" => user_id
         }
       }}
    end
  end

  defp lifecycle_details(%{status: :valid, effective_records: records}, user_id) do
    case List.last(records) do
      %{} = record ->
        with :ok <- owned_by?(record, user_id) do
          {:ok,
           %{
             category: record["payload"]["category"] || path_category(record, records),
             summary: record["payload"]["summary"] || "Memory claim #{record["claim_id"]}",
             state: record["state"],
             payload: lifecycle_payload(record["payload"])
           }}
        end

      nil ->
        {:error, :claim_has_no_effective_revision}
    end
  end

  defp lifecycle_details(%{status: status}, _user_id), do: {:error, status}

  defp stream_summary(stream) do
    %{
      claim_id: stream.claim_id,
      path: stream.path,
      expected_tail_digest: stream.tail_digest,
      legacy?: stream.legacy?,
      legacy_digest: stream.legacy_digest
    }
  end

  defp lifecycle_payload(payload) do
    Map.drop(
      payload,
      ~w[revision_id transition_id state recorded_at actor action legacy_adopted]
    )
  end

  defp maybe_put_legacy(transition, %{legacy?: true, path: path, legacy_digest: digest}) do
    transition
    |> Map.put("legacy_path", path)
    |> Map.put("legacy_digest", digest)
  end

  defp maybe_put_legacy(transition, _preview), do: transition

  defp valid_source_state("kept", operation) when operation in [:archive, :archive_nominated],
    do: :ok

  defp valid_source_state(state, :restore) when state in ["archived", "retired"], do: :ok

  defp valid_source_state("archived", operation) when operation in [:archive, :archive_nominated],
    do: {:error, :already_archived}

  defp valid_source_state(_state, :restore), do: {:error, :claim_not_archived}
  defp valid_source_state(_state, _operation), do: {:error, :invalid_claim_state_transition}

  defp owned_by?(record, user_id) do
    owner = record["payload"]["user_id"] || record["payload"]["operator_id"] || record["actor"]
    if owner == user_id, do: :ok, else: {:error, :not_found}
  end

  defp path_category(_record, _records), do: "notes"

  defp fetch_id(ids, key) do
    case Map.get(ids, key) || Map.get(ids, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_lifecycle_id, key}}
    end
  end

  defp required_actor(actor) when is_binary(actor) do
    actor = String.trim(actor)

    if actor != "" and byte_size(actor) <= 128 and not String.contains?(actor, ["\n", "\r"]),
      do: {:ok, actor},
      else: {:error, :invalid_lifecycle_actor}
  end

  defp required_actor(_actor), do: {:error, :invalid_lifecycle_actor}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
