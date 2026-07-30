defmodule AllbertAssist.Memory.Forget do
  @moduledoc """
  Tombstone-first, fail-closed destructive Forget recovery.

  Tombstones contain no claim text. Their keyed value token blocks an exact
  copied or moved legacy value, while their integrity tag authenticates the
  closed metadata and recovery phase through existing Key Custody.
  """

  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Claims.Format
  alias AllbertAssist.Memory.Projection
  alias AllbertAssist.Memory.Proposals
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.KeyCustody

  @domain "allbert.memory.forget-suppression.v1"
  @key_version 1
  @schema_version 1
  @normalizer_version 1
  @header "# Allbert Memory Forget Tombstone v1\n\n"
  @reason_codes ~w[operator_requested privacy incorrect expired]
  @claim_id_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  @tombstone_fields ~w[schema_version claim_id deleted_at actor reason_code phase normalizer_version key_ref key_version suppression_token integrity_tag]

  @doc "Return the exact transient claim preview and honest Forget boundary."
  def preview(claim_id) do
    with {:ok, stream} <- Claims.read(claim_id),
         record when is_map(record) <- List.last(stream.effective_records) do
      {:ok,
       %{
         claim_id: claim_id,
         expected_tail_digest: stream.tail_digest,
         current: record,
         disclosure:
           "Forget removes active Allbert Memory claim/projection copies and blocks exact re-proposal. " <>
             "The originating conversation is retained and remains searchable; use the separately " <>
             "confirmed canonical conversation delete action to remove it. Backups, snapshots, exports, " <>
             "forensics, filesystem/device remnants, and copies outside this active Home are not erased."
       }}
    else
      nil -> {:error, :grandfathered_claim_requires_adoption}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Begin or resume an exact confirmed Forget operation."
  def forget(claim_id, expected_tail_digest, actor, reason_code) do
    with :ok <- valid_claim_id(claim_id) do
      path = tombstone_path(claim_id)

      if File.exists?(path) do
        resume(claim_id)
      else
        begin_forget(claim_id, expected_tail_digest, actor, reason_code)
      end
    end
  end

  @doc "Resume one pending tombstone without claim content in durable recovery state."
  def resume(claim_id) do
    with :ok <- valid_claim_id(claim_id),
         {:ok, tombstone} <- read_tombstone(claim_id) do
      resume_tombstone(tombstone)
    end
  end

  @doc "Return content-free recovery state for one verified Forget tombstone."
  def recovery_status(claim_id) do
    with :ok <- valid_claim_id(claim_id),
         {:ok, tombstone} <- read_tombstone(claim_id) do
      {:ok,
       %{
         claim_id: tombstone["claim_id"],
         deleted_at: tombstone["deleted_at"],
         reason_code: tombstone["reason_code"],
         phase: String.to_existing_atom(tombstone["phase"])
       }}
    end
  end

  @doc "Complete every verified pending tombstone with one projection replacement."
  def reconcile_pending do
    with {:ok, tombstones} <- load_tombstones() do
      pending = Enum.filter(tombstones, &(&1["phase"] == "pending"))
      reconcile_pending_tombstones(pending)
    end
  end

  defp resume_tombstone(%{"phase" => "complete"} = tombstone) do
    {:ok, %{status: :already_complete, tombstone: tombstone}}
  end

  defp resume_tombstone(tombstone) do
    with claim_id <- tombstone["claim_id"],
         {:ok, _scrubbed} <- Proposals.scrub_forgotten(claim_id),
         :ok <- delete_claim_if_present(claim_id),
         :ok <- replace_projection(claim_id),
         {:ok, completed} <- complete_tombstone(tombstone) do
      {:ok, %{status: :complete, tombstone: completed}}
    end
  end

  defp reconcile_pending_tombstones([]),
    do: {:ok, %{pending_count: 0, completed_count: 0, projection_replaced?: false}}

  defp reconcile_pending_tombstones(pending) do
    claim_ids = Enum.map(pending, & &1["claim_id"])

    with :ok <- delete_pending_claims(claim_ids),
         :ok <- Projection.replace_after_forgets(claim_ids),
         {:ok, completed} <- complete_pending_tombstones(pending) do
      {:ok,
       %{
         pending_count: length(pending),
         completed_count: length(completed),
         projection_replaced?: true
       }}
    end
  end

  defp delete_pending_claims(claim_ids) do
    Enum.reduce_while(claim_ids, :ok, fn claim_id, :ok ->
      with {:ok, _scrubbed} <- Proposals.scrub_forgotten(claim_id),
           :ok <- delete_claim_if_present(claim_id) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp complete_pending_tombstones(tombstones) do
    Enum.reduce_while(tombstones, {:ok, []}, fn tombstone, {:ok, acc} ->
      case complete_tombstone(tombstone) do
        {:ok, completed} -> {:cont, {:ok, [completed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Read and verify every tombstone before Memory retrieval becomes ready."
  def load_tombstones do
    Paths.memory_tombstones_root()
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case read_tombstone_path(path) do
        {:ok, tombstone} -> {:cont, {:ok, [tombstone | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tombstones} -> {:ok, Enum.reverse(tombstones)}
      error -> error
    end
  end

  @doc "Return true only when a verified tombstone suppresses this exact normalized value."
  def suppressed_value?(value) do
    with {:ok, tombstones} <- load_tombstones() do
      suppressed_value?(value, tombstones)
    end
  end

  @doc false
  def suppressed_value?(value, tombstones) when is_list(tombstones) do
    fields = suppression_fields(normalize_value(value))

    {:ok,
     Enum.any?(tombstones, fn tombstone ->
       with {:ok, tag} <- decode_tag(tombstone["suppression_token"]),
            {:ok, true} <-
              KeyCustody.verify_system_hmac(
                @domain,
                fields,
                tag,
                tombstone["key_ref"],
                tombstone["key_version"]
              ) do
         true
       else
         _other -> false
       end
     end)}
  end

  defp begin_forget(claim_id, expected_tail_digest, actor, reason_code) do
    with {:ok, actor} <- required_actor(actor),
         :ok <- valid_reason_code(reason_code) do
      Claims.with_claim_lock(claim_id, expected_tail_digest, fn stream ->
        forget_locked(stream, claim_id, actor, reason_code)
      end)
    end
  end

  defp forget_locked(stream, claim_id, actor, reason_code) do
    with record when is_map(record) <- List.last(stream.effective_records),
         value <- claim_value(record["payload"]),
         {:ok, tombstone} <- pending_tombstone(claim_id, actor, reason_code, value),
         :ok <- write_tombstone(tombstone),
         {:ok, _scrubbed} <- Proposals.scrub_forgotten(claim_id),
         :ok <- delete_claim_file(stream.path) do
      continue_after_delete(claim_id, tombstone)
    else
      nil -> {:error, :claim_has_no_effective_revision}
      {:error, reason} -> {:error, reason}
    end
  end

  defp continue_after_delete(claim_id, tombstone) do
    with :ok <- replace_projection(claim_id),
         {:ok, completed} <- complete_tombstone(tombstone) do
      {:ok, %{status: :complete, tombstone: completed}}
    end
  end

  defp pending_tombstone(claim_id, actor, reason_code, value) do
    deleted_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    with {:ok, suppression} <-
           KeyCustody.system_hmac(
             @domain,
             suppression_fields(normalize_value(value)),
             @key_version
           ) do
      base = %{
        "schema_version" => @schema_version,
        "claim_id" => claim_id,
        "deleted_at" => deleted_at,
        "actor" => actor,
        "reason_code" => reason_code,
        "phase" => "pending",
        "normalizer_version" => @normalizer_version,
        "key_ref" => suppression.key_ref,
        "key_version" => suppression.key_version,
        "suppression_token" => encode_tag(suppression.tag)
      }

      sign_tombstone(base)
    else
      {:error, _reason} -> {:error, :memory_integrity_key_unavailable}
    end
  end

  defp complete_tombstone(%{"phase" => "complete"} = tombstone), do: {:ok, tombstone}

  defp complete_tombstone(tombstone) do
    with {:ok, completed} <- tombstone |> Map.put("phase", "complete") |> sign_tombstone(),
         :ok <- write_tombstone(completed) do
      {:ok, completed}
    end
  end

  defp sign_tombstone(tombstone) do
    unsigned = Map.delete(tombstone, "integrity_tag")

    with {:ok, hmac} <-
           KeyCustody.system_hmac(@domain, tombstone_integrity_fields(unsigned), @key_version) do
      {:ok,
       unsigned
       |> Map.put("key_ref", hmac.key_ref)
       |> Map.put("key_version", hmac.key_version)
       |> Map.put("integrity_tag", encode_tag(hmac.tag))}
    else
      {:error, _reason} -> {:error, :memory_integrity_key_unavailable}
    end
  end

  defp read_tombstone(claim_id), do: claim_id |> tombstone_path() |> read_tombstone_path()

  defp read_tombstone_path(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, tombstone} <- decode_tombstone(bytes),
         :ok <- validate_tombstone(tombstone, path) do
      {:ok, tombstone}
    else
      {:error, :enoent} -> {:error, :tombstone_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_tombstone(@header <> json) do
    case Jason.decode(json) do
      {:ok, %{} = tombstone} -> {:ok, tombstone}
      {:ok, _other} -> {:error, :invalid_tombstone_shape}
      {:error, _reason} -> {:error, :invalid_tombstone_json}
    end
  end

  defp decode_tombstone(_bytes), do: {:error, :invalid_tombstone_header}

  defp validate_tombstone(tombstone, path) do
    expected_claim_id = Path.basename(path, ".md")

    with true <-
           Enum.sort(Map.keys(tombstone)) == Enum.sort(@tombstone_fields) ||
             {:error, :invalid_tombstone_fields},
         true <-
           tombstone["schema_version"] == @schema_version ||
             {:error, :unsupported_tombstone_schema},
         :ok <- valid_claim_id(tombstone["claim_id"]),
         true <-
           tombstone["claim_id"] == expected_claim_id ||
             {:error, :tombstone_claim_id_mismatch},
         :ok <- valid_deleted_at(tombstone["deleted_at"]),
         {:ok, _actor} <- required_actor(tombstone["actor"]),
         true <- tombstone["phase"] in ~w[pending complete] || {:error, :invalid_tombstone_phase},
         true <-
           tombstone["reason_code"] in @reason_codes ||
             {:error, :invalid_tombstone_reason},
         true <-
           tombstone["normalizer_version"] == @normalizer_version ||
             {:error, :unsupported_tombstone_normalizer},
         {:ok, _suppression} <- decode_tag(tombstone["suppression_token"]),
         {:ok, integrity} <- decode_tag(tombstone["integrity_tag"]),
         {:ok, verified?} <-
           KeyCustody.verify_system_hmac(
             @domain,
             tombstone |> Map.delete("integrity_tag") |> tombstone_integrity_fields(),
             integrity,
             tombstone["key_ref"],
             tombstone["key_version"]
           ),
         true <- verified? || {:error, :invalid_tombstone_integrity} do
      :ok
    else
      {:error, {:system_integrity_key_unavailable, _version}} ->
        {:error, :tombstone_key_unavailable}

      {:error, _reason} = error ->
        error
    end
  end

  defp tombstone_integrity_fields(tombstone) do
    [
      "schema:#{tombstone["schema_version"]}",
      "claim_id:#{tombstone["claim_id"]}",
      "deleted_at:#{tombstone["deleted_at"]}",
      "actor:#{tombstone["actor"]}",
      "reason_code:#{tombstone["reason_code"]}",
      "phase:#{tombstone["phase"]}",
      "normalizer:#{tombstone["normalizer_version"]}",
      "suppression_token:#{tombstone["suppression_token"]}"
    ]
  end

  defp suppression_fields(normalized_value) do
    ["normalizer:#{@normalizer_version}", "value:#{normalized_value}"]
  end

  defp normalize_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> :unicode.characters_to_nfc_binary()
  end

  defp claim_value(payload) do
    payload["value"] || payload["object"] || payload["body"] || payload["claim"] ||
      Format.canonical_json(payload)
  end

  defp replace_projection(claim_id) do
    case Process.whereis(Projection) do
      nil -> {:error, :memory_projection_unavailable}
      _pid -> Projection.replace_after_forget(claim_id)
    end
  end

  defp delete_claim_if_present(claim_id) do
    case Claims.read(claim_id) do
      {:ok, stream} -> delete_claim_file(stream.path)
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_claim_file(path) do
    case File.rm(path) do
      :ok -> sync_directory(Path.dirname(path))
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:claim_delete_failed, reason}}
    end
  end

  defp write_tombstone(tombstone) do
    path = tombstone_path(tombstone["claim_id"])
    directory = Path.dirname(path)
    tmp = path <> ".tmp-" <> Ecto.UUID.generate()
    bytes = @header <> Format.canonical_json(tombstone) <> "\n"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(tmp, bytes, [:binary, :exclusive]),
         :ok <- File.chmod(tmp, 0o600),
         {:ok, io} <- File.open(tmp, [:read, :binary]),
         :ok <- sync_and_close(io),
         :ok <- File.rename(tmp, path),
         :ok <- sync_directory(directory) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:tombstone_write_failed, reason}}
    end
  end

  defp sync_and_close(io) do
    try do
      :file.sync(io)
    after
      File.close(io)
    end
  end

  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :directory]) do
      {:ok, io} -> sync_and_close(io)
      {:error, :eisdir} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp required_actor(actor) when is_binary(actor) do
    actor = String.trim(actor)

    if actor != "" and byte_size(actor) <= 128 and not String.contains?(actor, ["\n", "\r"]),
      do: {:ok, actor},
      else: {:error, :invalid_forget_actor}
  end

  defp required_actor(_actor), do: {:error, :invalid_forget_actor}

  defp valid_deleted_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> :ok
      _other -> {:error, :invalid_tombstone_timestamp}
    end
  end

  defp valid_deleted_at(_value), do: {:error, :invalid_tombstone_timestamp}

  defp valid_reason_code(reason_code) when reason_code in @reason_codes, do: :ok
  defp valid_reason_code(_reason_code), do: {:error, :invalid_forget_reason_code}

  defp valid_claim_id(value) when is_binary(value) do
    if Regex.match?(@claim_id_pattern, value), do: :ok, else: {:error, :invalid_claim_id}
  end

  defp valid_claim_id(_value), do: {:error, :invalid_claim_id}
  defp tombstone_path(claim_id), do: Path.join(Paths.memory_tombstones_root(), claim_id <> ".md")

  defp decode_tag("hmac-sha256:" <> hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, tag} when byte_size(tag) == 32 -> {:ok, tag}
      _other -> {:error, :invalid_tombstone_tag}
    end
  end

  defp decode_tag(_value), do: {:error, :invalid_tombstone_tag}
  defp encode_tag(tag), do: "hmac-sha256:" <> Base.encode16(tag, case: :lower)
end
