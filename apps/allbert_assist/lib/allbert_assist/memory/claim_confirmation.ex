defmodule AllbertAssist.Memory.ClaimConfirmation do
  @moduledoc """
  Exact, content-free authority transitions for manual and destination claims.

  The candidate content is read transiently from the Markdown stream. Durable
  confirmation state binds only the unchanged chain digest plus retry-stable
  IDs and timestamp; `Memory.Claims` performs the final locked CAS and signs
  the authority transition through Key Custody.
  """

  alias AllbertAssist.Memory.Claims

  @doc "Prepare an exact raw-manual-revision confirmation."
  def prepare_manual(claim_id, actor) do
    with {:ok, stream} <- Claims.read(claim_id),
         true <- stream.status == :pending_manual || {:error, :manual_revision_missing},
         %{} = pending <- List.last(stream.records) || {:error, :manual_revision_missing},
         true <-
           pending["authority_kind"] == "manual_revision" ||
             {:error, :manual_revision_missing} do
      {:ok,
       %{
         preview: pending["payload"],
         binding: %{
           claim_id: claim_id,
           expected_tail_digest: stream.tail_digest,
           pending_revision_digest: pending["revision_digest"],
           prior_chain_digest: pending["previous_revision_digest"],
           state: pending["state"],
           valid_from: pending["valid_from"],
           valid_to: pending["valid_to"],
           actor: actor,
           recorded_at: now(),
           revision_id: Ecto.UUID.generate(),
           transition_id: Ecto.UUID.generate()
         }
       }}
    else
      {:ok, %{status: status}} -> {:error, status}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Append the exact prepared manual-confirmation transition."
  def confirm_manual(binding) when is_map(binding) do
    binding = stringify(binding)

    Claims.append(
      binding["claim_id"],
      binding["expected_tail_digest"],
      confirmation_transition(binding, "manual_import_confirmed", %{
        "pending_revision_digest" => binding["pending_revision_digest"],
        "prior_chain_digest" => binding["prior_chain_digest"]
      })
    )
  end

  def confirm_manual(_binding), do: {:error, :invalid_manual_confirmation_binding}

  @doc "Prepare exact-whole-chain confirmation for a foreign Home claim."
  def prepare_destination(claim_id, actor) do
    with {:ok, stream} <- Claims.inspect_destination(claim_id),
         true <-
           stream.status == :destination_confirmation_required ||
             {:error, :destination_confirmation_not_required},
         %{} = tail <- List.last(stream.records) || {:error, :empty_claim_stream} do
      {:ok,
       %{
         preview: %{
           claim_id: claim_id,
           path: stream.path,
           record_count: length(stream.records),
           source_chain_digest: stream.tail_digest,
           records: stream.records
         },
         binding: %{
           claim_id: claim_id,
           expected_tail_digest: stream.tail_digest,
           source_chain_digest: stream.tail_digest,
           prior_chain_digest: stream.tail_digest,
           state: tail["state"],
           valid_from: tail["valid_from"],
           valid_to: tail["valid_to"],
           actor: actor,
           recorded_at: now(),
           revision_id: Ecto.UUID.generate(),
           transition_id: Ecto.UUID.generate()
         }
       }}
    else
      {:ok, %{status: status}} -> {:error, status}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Append the exact prepared destination-chain confirmation transition."
  def confirm_destination(binding) when is_map(binding) do
    binding = stringify(binding)

    Claims.append(
      binding["claim_id"],
      binding["expected_tail_digest"],
      confirmation_transition(binding, "destination_chain_confirmed", %{
        "source_chain_digest" => binding["source_chain_digest"],
        "prior_chain_digest" => binding["prior_chain_digest"]
      })
    )
  end

  def confirm_destination(_binding), do: {:error, :invalid_destination_confirmation_binding}

  defp confirmation_transition(binding, action, exact_binding) do
    %{
      "revision_id" => binding["revision_id"],
      "transition_id" => binding["transition_id"],
      "state" => binding["state"],
      "recorded_at" => binding["recorded_at"],
      "valid_from" => binding["valid_from"],
      "valid_to" => binding["valid_to"],
      "actor" => binding["actor"],
      "action" => action,
      "normalizer_version" => 1
    }
    |> Map.merge(exact_binding)
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
