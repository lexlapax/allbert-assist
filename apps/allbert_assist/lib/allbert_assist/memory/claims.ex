defmodule AllbertAssist.Memory.Claims do
  @moduledoc """
  Canonical append-only claim-stream reader and compare-and-append writer.

  The filesystem stream is the state machine. A per-claim lock serializes the
  final tombstone/tail recheck and same-directory durable replace; no process or
  Repo table becomes claim authority.
  """

  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Claims.Format
  alias AllbertAssist.Memory.Claims.LegacyIdentity
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.KeyCustody

  @domain "allbert.memory.claim-transition.v1"
  @manual_domain "allbert.memory.manual-confirmation.v1"
  @destination_domain "allbert.memory.destination-chain-confirmation.v1"
  @key_version 1
  @schema_version 1
  @normalizer_version 1
  @digest_pattern ~r/^sha256:[0-9a-f]{64}$/
  @states ~w[kept archived retired]
  @claim_id_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  @type stream :: %{
          claim_id: String.t(),
          path: String.t(),
          legacy?: boolean(),
          legacy_digest: String.t() | nil,
          records: [map()],
          effective_records: [map()],
          tail_digest: String.t() | nil,
          status: :valid | :grandfathered | :pending_manual | :destination_confirmation_required
        }

  @doc "Append one native transition after the exact expected tail."
  @spec append(String.t(), String.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def append(claim_id, expected_tail_digest, transition) when is_map(transition) do
    with :ok <- valid_claim_id(claim_id),
         :ok <- valid_expected_tail(expected_tail_digest),
         {:ok, target} <- append_target(claim_id, transition) do
      lock(claim_id, fn -> append_locked(target, expected_tail_digest, transition) end)
    end
  end

  def append(_claim_id, _expected_tail_digest, _transition), do: {:error, :invalid_transition}

  @doc "Read and verify one logical claim by embedded or deterministic legacy id."
  @spec read(String.t()) :: {:ok, stream()} | {:error, term()}
  def read(claim_id) do
    with :ok <- valid_claim_id(claim_id),
         {:ok, path} <- locate_claim(claim_id) do
      read_path(path, expected_claim_id: claim_id)
    end
  end

  @doc "Inspect one structurally valid foreign chain for explicit destination confirmation."
  @spec inspect_destination(String.t()) :: {:ok, stream()} | {:error, term()}
  def inspect_destination(claim_id) do
    with :ok <- valid_claim_id(claim_id),
         {:ok, path} <- locate_claim(claim_id) do
      read_path(path, expected_claim_id: claim_id, allow_foreign: true)
    end
  end

  @doc "Read and verify one claim stream or grandfathered legacy file by path."
  @spec read_path(String.t(), keyword()) :: {:ok, stream()} | {:error, term()}
  def read_path(path, opts \\ [])

  def read_path(path, opts) when is_binary(path) do
    expected_claim_id = Keyword.get(opts, :expected_claim_id)
    allow_foreign? = Keyword.get(opts, :allow_foreign, false)

    with {:ok, content} <- File.read(path) do
      case Format.parse(content) do
        {:ok, parsed} -> validate_parsed(path, parsed, expected_claim_id, allow_foreign?)
        {:error, :not_claim_stream} -> load_legacy(path, content, expected_claim_id)
        {:error, reason} -> quarantine(path, reason)
      end
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, {:claim_read_failed, reason}}
    end
  end

  def read_path(_path, _opts), do: {:error, :invalid_claim_path}

  @doc "Return the current authoritative record, including archived/retired state."
  @spec current(String.t()) :: {:ok, map()} | {:error, term()}
  def current(claim_id) do
    with {:ok, %{status: :valid} = stream} <- read(claim_id),
         record when is_map(record) <- List.last(stream.effective_records) do
      {:ok, record}
    else
      nil -> {:error, :grandfathered_claim_requires_adoption}
      {:ok, %{status: status}} -> {:error, status}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Return the newest kept record valid at both explicit temporal axes."
  @spec as_of(String.t(), DateTime.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def as_of(claim_id, %DateTime{} = valid_at, %DateTime{} = known_at) do
    with {:ok, %{status: :valid} = stream} <- read(claim_id) do
      stream.effective_records
      |> Enum.filter(&known_by?(&1, known_at))
      |> Enum.filter(&valid_at?(&1, valid_at))
      |> List.last()
      |> case do
        nil -> {:error, :not_effective}
        %{"state" => "kept"} = record -> {:ok, record}
        _record -> {:error, :not_effective}
      end
    else
      {:ok, %{status: status}} -> {:error, status}
      {:error, reason} -> {:error, reason}
    end
  end

  def as_of(_claim_id, _valid_at, _known_at), do: {:error, :invalid_temporal_view}

  @doc "Return the frozen deterministic id and complete digest for a legacy file."
  @spec legacy_identity(String.t()) :: {:ok, map()} | {:error, term()}
  def legacy_identity(path) do
    with {:ok, content} <- File.read(path),
         category <- path |> Path.dirname() |> Path.basename(),
         :ok <- legacy_category(category),
         {:ok, claim_id} <- LegacyIdentity.derive(category, path, Memory.root()) do
      {:ok, %{claim_id: claim_id, digest: digest(content), category: category, path: path}}
    end
  end

  @doc "Return every discovered claim path; hidden/temp/deleted/tombstone files are excluded."
  def claim_paths do
    Memory.categories()
    |> Enum.flat_map(fn category ->
      Path.wildcard(Path.join([Memory.root(), Atom.to_string(category), "*.md"]))
    end)
    |> Enum.reject(&(Path.basename(&1) |> String.starts_with?(".")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp append_locked(target, expected_tail_digest, transition) do
    allow_foreign? = field(transition, :action) == "destination_chain_confirmed"

    with :ok <- tombstone_absent(target.claim_id),
         {:ok, stream} <- load_target(target, allow_foreign: allow_foreign?),
         {:ok, normalized} <- normalize_transition(transition, stream),
         {:new, normalized} <- transition_disposition(stream, normalized),
         :ok <- check_expected_tail(stream.tail_digest, expected_tail_digest),
         :ok <- authorize_transition(stream, normalized),
         {:ok, record} <- signed_record(stream, normalized),
         :ok <- tombstone_absent(target.claim_id),
         :ok <-
           durable_replace(
             stream.path,
             Format.render(stream.legacy_content, stream.records ++ [record])
           ) do
      {:ok,
       %{
         outcome: :appended,
         claim_id: target.claim_id,
         revision_id: record["revision_id"],
         transition_id: record["transition_id"],
         tail_digest: record["revision_digest"],
         sequence: record["sequence"],
         path: stream.path
       }}
    else
      {:retry, record} ->
        {:ok,
         %{
           outcome: :already_committed,
           claim_id: target.claim_id,
           revision_id: record["revision_id"],
           transition_id: record["transition_id"],
           tail_digest: record["revision_digest"],
           sequence: record["sequence"],
           path: target.path
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_target(claim_id, transition) do
    legacy_path = field(transition, :legacy_path)

    if is_binary(legacy_path) and legacy_path != "" do
      legacy_target(claim_id, legacy_path, field(transition, :legacy_digest))
    else
      case locate_claim(claim_id) do
        {:ok, path} -> existing_target(claim_id, path)
        {:error, :not_found} -> new_target(claim_id, transition)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp legacy_target(claim_id, path, expected_digest) do
    case read_path(path, expected_claim_id: claim_id) do
      {:ok, %{records: [_first | _rest], legacy_digest: digest}} ->
        if digest == expected_digest,
          do: existing_target(claim_id, path),
          else: {:error, :legacy_digest_mismatch}

      {:ok, %{records: [], legacy_digest: digest}} ->
        if digest == expected_digest,
          do: {:ok, %{claim_id: claim_id, path: path, legacy?: true, legacy_digest: digest}},
          else: {:error, :legacy_digest_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_target(claim_id, path) do
    {:ok, %{claim_id: claim_id, path: path, legacy?: :existing, legacy_digest: nil}}
  end

  defp new_target(claim_id, transition) do
    with {:ok, category} <- claim_category(field(transition, :category)) do
      {:ok,
       %{
         claim_id: claim_id,
         path: Path.join([Memory.root(), category, claim_id <> ".md"]),
         legacy?: false,
         legacy_digest: nil
       }}
    end
  end

  defp load_target(%{legacy?: false, path: path, claim_id: claim_id}, opts) do
    if File.exists?(path) do
      read_path(path, Keyword.put(opts, :expected_claim_id, claim_id)) |> stream_for_append()
    else
      {:ok, empty_stream(path, claim_id)}
    end
  end

  defp load_target(
         %{legacy?: true, path: path, claim_id: claim_id, legacy_digest: digest},
         opts
       ) do
    with {:ok, content} <- File.read(path),
         {:ok, stream} <- read_path(path, Keyword.put(opts, :expected_claim_id, claim_id)),
         true <- stream.legacy? || {:error, :legacy_already_rehomed},
         true <- stream.legacy_digest == digest || {:error, :legacy_digest_mismatch} do
      {:ok, Map.put(stream, :legacy_content, legacy_content(content))}
    end
  end

  defp load_target(%{legacy?: :existing, path: path, claim_id: claim_id}, opts) do
    read_path(path, Keyword.put(opts, :expected_claim_id, claim_id))
  end

  defp stream_for_append({:ok, stream}), do: {:ok, Map.put(stream, :legacy_content, nil)}
  defp stream_for_append(error), do: error

  defp empty_stream(path, claim_id) do
    %{
      claim_id: claim_id,
      path: path,
      legacy?: false,
      legacy_content: nil,
      legacy_digest: nil,
      records: [],
      effective_records: [],
      tail_digest: nil,
      status: :valid
    }
  end

  defp validate_parsed(path, parsed, expected_claim_id, allow_foreign?) do
    with {:ok, claim_id} <- stream_claim_id(parsed.records, expected_claim_id),
         {:ok, base} <- parsed_base(path, parsed, claim_id),
         {:ok, records} <- validate_records(parsed.records, base),
         :ok <- unique_transition_ids(records),
         {:ok, authority} <- authorize_records(records, allow_foreign?) do
      {:ok,
       %{
         claim_id: claim_id,
         path: path,
         legacy?: not is_nil(parsed.legacy_content),
         legacy_content: parsed.legacy_content,
         legacy_digest: base.legacy_digest,
         records: records,
         effective_records: authority.effective_records,
         tail_digest: tail_digest(records, base.legacy_digest),
         status: authority.status
       }}
    else
      {:error, reason} -> quarantine(path, reason)
    end
  end

  defp stream_claim_id([], _expected_claim_id), do: {:error, :empty_claim_stream}

  defp stream_claim_id([first | _rest], expected_claim_id) do
    claim_id = first["claim_id"]

    with :ok <- valid_claim_id(claim_id),
         true <-
           (is_nil(expected_claim_id) or claim_id == expected_claim_id) ||
             {:error, :claim_id_mismatch} do
      {:ok, claim_id}
    end
  end

  defp parsed_base(_path, %{legacy_content: nil}, claim_id) do
    {:ok, %{claim_id: claim_id, legacy_digest: nil, previous: nil}}
  end

  defp parsed_base(_path, %{legacy_content: content, records: [first | _rest]}, claim_id) do
    legacy_digest = digest(content)

    with %{"claim_id" => ^claim_id, "legacy_digest" => ^legacy_digest} <-
           get_in(first, ["payload", "legacy_adopted"]) || %{} do
      {:ok,
       %{
         claim_id: claim_id,
         legacy_digest: legacy_digest,
         previous: legacy_digest
       }}
    else
      _other -> {:error, :invalid_legacy_adoption}
    end
  end

  defp validate_records(records, base) do
    records
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], base.previous}, fn {record, sequence}, {:ok, acc, previous} ->
      case validate_record(record, base.claim_id, sequence, previous) do
        :ok -> {:cont, {:ok, [record | acc], record["revision_digest"]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records, _tail} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp validate_record(record, expected_claim_id, sequence, previous) do
    with :ok <- required_record_shape(record),
         true <-
           (is_nil(expected_claim_id) or record["claim_id"] == expected_claim_id) ||
             {:error, :claim_id_mismatch},
         true <- record["sequence"] == sequence || {:error, :revision_sequence_mismatch},
         true <-
           record["previous_revision_digest"] == previous ||
             {:error, :revision_link_mismatch},
         true <-
           record["payload_digest"] == digest(Format.canonical_json(record["payload"])) ||
             {:error, :payload_digest_mismatch},
         true <-
           record["revision_digest"] == revision_digest(record) ||
             {:error, :revision_digest_mismatch} do
      :ok
    end
  end

  defp required_record_shape(record) do
    required =
      ~w[schema_version claim_id revision_id sequence previous_revision_digest payload payload_digest transition_id state recorded_at actor action normalizer_version authority_kind key_ref key_version revision_digest integrity_tag]

    cond do
      Enum.any?(required, &(not Map.has_key?(record, &1))) ->
        {:error, :missing_revision_field}

      record["schema_version"] != @schema_version ->
        {:error, :unsupported_claim_schema}

      record["state"] not in @states ->
        {:error, :invalid_claim_state}

      record["authority_kind"] not in ~w[native manual_revision manual_confirmation destination_confirmation] ->
        {:error, :invalid_authority_kind}

      true ->
        :ok
    end
  end

  defp authorize_records(records, allow_foreign?) do
    granted_through = destination_grant_sequence(records)

    initial = %{
      effective_records: [],
      pending: nil,
      destination_required?: allow_foreign? and is_nil(granted_through),
      allow_foreign?: allow_foreign?,
      granted_through: granted_through,
      seen: []
    }

    records
    |> Enum.reduce_while({:ok, initial}, fn record, {:ok, state} ->
      case authorize_record(record, state) do
        {:ok, state} -> {:cont, {:ok, %{state | seen: state.seen ++ [record]}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, %{destination_required?: true}} ->
        {:ok, %{status: :destination_confirmation_required, effective_records: []}}

      {:ok, %{pending: %{}, effective_records: records}} ->
        {:ok, %{status: :pending_manual, effective_records: records}}

      {:ok, %{effective_records: records}} ->
        {:ok, %{status: :valid, effective_records: records}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authorize_record(%{"authority_kind" => "native"} = record, state) do
    with true <- is_nil(state.pending) || {:error, :manual_confirmation_required},
         true <-
           record["action"] not in ~w[manual_import_confirmed destination_chain_confirmed] ||
             {:error, :authority_action_mismatch} do
      case verify_integrity(record, @domain) do
        :ok ->
          {:ok, %{state | effective_records: state.effective_records ++ [record]}}

        {:error, reason}
        when reason in [:invalid_integrity_tag, :memory_integrity_key_unavailable] ->
          accept_foreign(record, state, reason, %{})

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp authorize_record(%{"authority_kind" => "manual_revision"} = record, state) do
    with true <- is_nil(state.pending) || {:error, :multiple_pending_manual_revisions},
         true <-
           record["action"] not in ~w[manual_import_confirmed destination_chain_confirmed] ||
             {:error, :authority_action_mismatch},
         true <-
           (is_nil(record["key_ref"]) and is_nil(record["key_version"]) and
              is_nil(record["integrity_tag"])) || {:error, :manual_revision_has_authority_tag} do
      {:ok, %{state | pending: record}}
    end
  end

  defp authorize_record(%{"authority_kind" => "manual_confirmation"} = record, state) do
    with true <-
           record["action"] == "manual_import_confirmed" ||
             {:error, :authority_action_mismatch},
         true <-
           content_free_confirmation?(record["payload"], "pending_revision_digest") ||
             {:error, :confirmation_contains_claim_content},
         %{} = pending <- state.pending || {:error, :manual_revision_missing},
         true <-
           manual_confirmation_matches?(record, pending) ||
             {:error, :manual_confirmation_mismatch} do
      case verify_integrity(record, @manual_domain) do
        :ok ->
          {:ok,
           %{
             state
             | effective_records: state.effective_records ++ [pending],
               pending: nil
           }}

        {:error, reason}
        when reason in [:invalid_integrity_tag, :memory_integrity_key_unavailable] ->
          accept_foreign(record, state, reason, %{pending: nil})

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp authorize_record(%{"authority_kind" => "destination_confirmation"} = record, state) do
    with true <-
           record["action"] == "destination_chain_confirmed" ||
             {:error, :authority_action_mismatch},
         true <-
           content_free_confirmation?(record["payload"], "source_chain_digest") ||
             {:error, :confirmation_contains_claim_content},
         true <-
           record["payload"]["source_chain_digest"] == record["previous_revision_digest"] ||
             {:error, :destination_confirmation_mismatch} do
      case verify_integrity(record, @destination_domain) do
        :ok ->
          effective_records =
            state.seen
            |> Enum.filter(&(&1["authority_kind"] in ~w[native manual_revision]))

          {:ok,
           %{
             state
             | effective_records: effective_records,
               pending: nil,
               destination_required?: false
           }}

        {:error, reason}
        when reason in [:invalid_integrity_tag, :memory_integrity_key_unavailable] ->
          accept_foreign(record, state, reason, %{})

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp destination_grant_sequence(records) do
    records
    |> Enum.filter(&(&1["authority_kind"] == "destination_confirmation"))
    |> Enum.filter(&destination_confirmation_valid?/1)
    |> List.last()
    |> case do
      nil -> nil
      record -> record["sequence"] - 1
    end
  end

  defp destination_confirmation_valid?(record) do
    record["action"] == "destination_chain_confirmed" and
      content_free_confirmation?(record["payload"], "source_chain_digest") and
      record["payload"]["source_chain_digest"] == record["previous_revision_digest"] and
      verify_integrity(record, @destination_domain) == :ok
  end

  defp foreign_record_allowed?(record, state) do
    state.allow_foreign? or
      (is_integer(state.granted_through) and record["sequence"] <= state.granted_through)
  end

  defp accept_foreign(record, state, reason, updates) do
    if foreign_record_allowed?(record, state),
      do: {:ok, Map.merge(state, updates)},
      else: {:error, reason}
  end

  defp manual_confirmation_matches?(record, pending) do
    payload = record["payload"]

    payload["pending_revision_digest"] == pending["revision_digest"] and
      payload["prior_chain_digest"] == pending["previous_revision_digest"] and
      payload["normalizer_version"] == pending["normalizer_version"]
  end

  defp content_free_confirmation?(payload, binding_field) do
    allowed =
      ~w[revision_id transition_id state recorded_at valid_from valid_to actor action normalizer_version prior_chain_digest] ++
        [binding_field]

    Map.keys(payload) -- allowed == []
  end

  defp verify_integrity(record, domain) do
    with {:ok, tag} <- decode_tag(record["integrity_tag"]),
         {:ok, verified?} <-
           KeyCustody.verify_system_hmac(
             domain,
             integrity_fields(record),
             tag,
             record["key_ref"],
             record["key_version"]
           ),
         true <- verified? || {:error, :invalid_integrity_tag} do
      :ok
    else
      {:error, {:system_integrity_key_unavailable, _version}} ->
        {:error, :memory_integrity_key_unavailable}

      {:error, _reason} = error ->
        error
    end
  end

  defp load_legacy(path, content, expected_claim_id) do
    with {:ok, identity} <- legacy_identity_from_content(path, content),
         true <-
           (is_nil(expected_claim_id) or identity.claim_id == expected_claim_id) ||
             {:error, :claim_id_mismatch} do
      {:ok,
       %{
         claim_id: identity.claim_id,
         path: path,
         legacy?: true,
         legacy_content: content,
         legacy_digest: identity.digest,
         records: [],
         effective_records: [],
         tail_digest: identity.digest,
         status: :grandfathered
       }}
    end
  end

  defp legacy_identity_from_content(path, content) do
    category = path |> Path.dirname() |> Path.basename()

    with :ok <- legacy_category(category),
         {:ok, claim_id} <- LegacyIdentity.derive(category, path, Memory.root()) do
      {:ok, %{claim_id: claim_id, digest: digest(content)}}
    end
  end

  defp legacy_category(category) do
    if category in Enum.map(Memory.categories(), &Atom.to_string/1),
      do: :ok,
      else: {:error, :invalid_legacy_category}
  end

  defp claim_category(nil), do: {:ok, "notes"}

  defp claim_category(category) when is_atom(category),
    do: claim_category(Atom.to_string(category))

  defp claim_category(category) when is_binary(category) do
    category = String.trim(category)

    if category in Enum.map(Memory.categories(), &Atom.to_string/1),
      do: {:ok, category},
      else: {:error, :invalid_claim_category}
  end

  defp claim_category(_category), do: {:error, :invalid_claim_category}

  defp normalize_transition(transition, stream) do
    payload =
      transition
      |> stringify()
      |> Map.drop(~w[legacy_path legacy_digest])

    with {:ok, revision_id} <- required_id(payload, "revision_id"),
         {:ok, transition_id} <- required_id(payload, "transition_id"),
         {:ok, state} <- required_state(payload),
         {:ok, recorded_at} <- required_datetime(payload, "recorded_at"),
         {:ok, actor} <- required_string(payload, "actor"),
         {:ok, action} <- required_string(payload, "action"),
         :ok <- valid_interval(payload["valid_from"], payload["valid_to"]) do
      payload =
        payload
        |> Map.put("revision_id", revision_id)
        |> Map.put("transition_id", transition_id)
        |> Map.put("state", state)
        |> Map.put("recorded_at", recorded_at)
        |> Map.put("actor", actor)
        |> Map.put("action", action)
        |> Map.put_new("normalizer_version", @normalizer_version)
        |> maybe_legacy_adoption(stream)

      {:ok, payload}
    end
  end

  defp maybe_legacy_adoption(payload, %{
         legacy?: true,
         legacy_digest: digest,
         claim_id: claim_id,
         records: []
       }) do
    Map.put(payload, "legacy_adopted", %{"claim_id" => claim_id, "legacy_digest" => digest})
  end

  defp maybe_legacy_adoption(payload, _stream), do: payload

  defp signed_record(stream, payload) do
    {authority_kind, domain} = transition_authority(payload["action"])

    base = %{
      "schema_version" => @schema_version,
      "claim_id" => stream.claim_id,
      "revision_id" => payload["revision_id"],
      "sequence" => length(stream.records) + 1,
      "previous_revision_digest" => stream.tail_digest,
      "payload" => payload,
      "payload_digest" => digest(Format.canonical_json(payload)),
      "transition_id" => payload["transition_id"],
      "state" => payload["state"],
      "recorded_at" => payload["recorded_at"],
      "valid_from" => payload["valid_from"],
      "valid_to" => payload["valid_to"],
      "actor" => payload["actor"],
      "action" => payload["action"],
      "normalizer_version" => payload["normalizer_version"],
      "authority_kind" => authority_kind,
      "key_ref" => "secret://system/integrity_v1",
      "key_version" => @key_version
    }

    with {:ok, hmac} <- KeyCustody.system_hmac(domain, integrity_fields(base), @key_version) do
      record =
        base
        |> Map.put("key_ref", hmac.key_ref)
        |> Map.put("key_version", hmac.key_version)
        |> Map.put("revision_digest", revision_digest(base))
        |> Map.put("integrity_tag", encode_tag(hmac.tag))

      {:ok, record}
    else
      {:error, _reason} -> {:error, :memory_integrity_key_unavailable}
    end
  end

  defp transition_authority("manual_import_confirmed"),
    do: {"manual_confirmation", @manual_domain}

  defp transition_authority("destination_chain_confirmed"),
    do: {"destination_confirmation", @destination_domain}

  defp transition_authority(_action), do: {"native", @domain}

  defp integrity_fields(record) do
    [
      "schema:#{record["schema_version"]}",
      "claim_id:#{record["claim_id"]}",
      "revision_id:#{record["revision_id"]}",
      "sequence:#{record["sequence"]}",
      "previous:#{record["previous_revision_digest"] || ""}",
      "payload_digest:#{record["payload_digest"]}",
      "transition_id:#{record["transition_id"]}",
      "actor:#{record["actor"]}",
      "action:#{record["action"]}",
      "normalizer_version:#{record["normalizer_version"]}"
    ]
  end

  defp revision_digest(record) do
    record
    |> Map.drop(~w[revision_digest integrity_tag])
    |> Format.canonical_json()
    |> digest()
  end

  defp transition_disposition(stream, payload) do
    case Enum.find(stream.records, &(&1["transition_id"] == payload["transition_id"])) do
      nil ->
        {:new, payload}

      %{} = record ->
        if record["payload_digest"] == digest(Format.canonical_json(payload)),
          do: {:retry, record},
          else: {:error, :transition_id_conflict}
    end
  end

  defp authorize_transition(stream, %{"action" => "manual_import_confirmed"} = payload) do
    pending = List.last(stream.records)

    with true <- stream.status == :pending_manual || {:error, :manual_revision_missing},
         true <-
           content_free_confirmation?(payload, "pending_revision_digest") ||
             {:error, :confirmation_contains_claim_content},
         %{"authority_kind" => "manual_revision"} <- pending || %{},
         true <-
           payload["pending_revision_digest"] == pending["revision_digest"] ||
             {:error, :manual_confirmation_mismatch},
         true <-
           payload["prior_chain_digest"] == pending["previous_revision_digest"] ||
             {:error, :manual_confirmation_mismatch},
         true <-
           payload["normalizer_version"] == pending["normalizer_version"] ||
             {:error, :manual_confirmation_mismatch} do
      :ok
    else
      %{} -> {:error, :manual_revision_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_transition(stream, %{"action" => "destination_chain_confirmed"} = payload) do
    with true <-
           stream.status == :destination_confirmation_required ||
             {:error, :destination_confirmation_not_required},
         true <-
           content_free_confirmation?(payload, "source_chain_digest") ||
             {:error, :confirmation_contains_claim_content},
         true <-
           payload["source_chain_digest"] == stream.tail_digest ||
             {:error, :destination_confirmation_mismatch} do
      :ok
    end
  end

  defp authorize_transition(%{status: status}, _payload) when status in [:valid, :grandfathered],
    do: :ok

  defp authorize_transition(%{status: status}, _payload), do: {:error, status}

  defp check_expected_tail(actual, actual), do: :ok
  defp check_expected_tail(_actual, _expected), do: {:error, :stale_tail}

  defp tombstone_absent(claim_id) do
    path = Path.join(Paths.memory_tombstones_root(), claim_id <> ".md")
    if File.exists?(path), do: {:error, :forgotten}, else: :ok
  end

  defp durable_replace(path, content) do
    directory = Path.dirname(path)
    tmp = Path.join(directory, ".#{Path.basename(path)}.tmp-#{Ecto.UUID.generate()}")

    with :ok <- File.mkdir_p(directory),
         {:ok, mode} <- replacement_mode(path),
         :ok <- write_synced(tmp, content, mode),
         :ok <- File.rename(tmp, path),
         :ok <- sync_directory(directory) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:claim_write_failed, reason}}
    end
  end

  defp replacement_mode(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, Bitwise.band(stat.mode, 0o777)}
      {:error, :enoent} -> {:ok, 0o600}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_synced(path, content, mode) do
    with :ok <- File.write(path, content, [:binary, :exclusive]),
         :ok <- File.chmod(path, mode),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        :file.sync(io)
      after
        File.close(io)
      end
    end
  end

  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :directory]) do
      {:ok, io} ->
        try do
          :file.sync(io)
        after
          :file.close(io)
        end

      {:error, :eisdir} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp locate_claim(claim_id) do
    paths =
      claim_paths()
      |> Enum.filter(fn path -> claim_id_for_path(path) == claim_id end)

    case paths do
      [path] -> {:ok, path}
      [] -> {:error, :not_found}
      _many -> {:error, :duplicate_claim_id}
    end
  end

  defp claim_id_for_path(path) do
    case File.read(path) do
      {:ok, content} ->
        case Format.parse(content) do
          {:ok, %{records: [%{"claim_id" => claim_id} | _rest]}} -> claim_id
          _other -> legacy_id_for_path(path)
        end

      {:error, _reason} ->
        nil
    end
  end

  defp legacy_id_for_path(path) do
    case legacy_identity(path) do
      {:ok, identity} -> identity.claim_id
      {:error, _reason} -> nil
    end
  end

  defp unique_transition_ids(records) do
    ids = Enum.map(records, & &1["transition_id"])
    if length(ids) == length(Enum.uniq(ids)), do: :ok, else: {:error, :duplicate_transition_id}
  end

  defp tail_digest([], legacy_digest), do: legacy_digest
  defp tail_digest(records, _legacy_digest), do: List.last(records)["revision_digest"]

  defp legacy_content(content) do
    case Format.parse(content) do
      {:ok, %{legacy_content: legacy}} when is_binary(legacy) -> legacy
      _other -> content
    end
  end

  defp quarantine(path, reason), do: {:error, {:quarantined, reason, path}}

  defp valid_claim_id(value) when is_binary(value) do
    if Regex.match?(@claim_id_pattern, value), do: :ok, else: {:error, :invalid_claim_id}
  end

  defp valid_claim_id(_value), do: {:error, :invalid_claim_id}
  defp valid_expected_tail(nil), do: :ok

  defp valid_expected_tail(value) when is_binary(value) do
    if Regex.match?(@digest_pattern, value), do: :ok, else: {:error, :invalid_expected_tail}
  end

  defp valid_expected_tail(_value), do: {:error, :invalid_expected_tail}

  defp required_id(payload, key) do
    with {:ok, value} <- required_string(payload, key),
         :ok <- valid_claim_id(value) do
      {:ok, value}
    end
  end

  defp required_state(payload) do
    case payload["state"] do
      state when state in @states -> {:ok, state}
      _other -> {:error, :invalid_claim_state}
    end
  end

  defp required_datetime(payload, key) do
    with {:ok, value} <- required_string(payload, key),
         {:ok, datetime, 0} <- DateTime.from_iso8601(value) do
      {:ok, DateTime.to_iso8601(datetime)}
    else
      _other -> {:error, {:invalid_datetime, key}}
    end
  end

  defp required_string(payload, key) do
    case payload[key] do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, {:missing_transition_field, key}}, else: {:ok, value}

      _other ->
        {:error, {:missing_transition_field, key}}
    end
  end

  defp valid_interval(valid_from, valid_to) do
    with {:ok, from} <- optional_datetime(valid_from),
         {:ok, to} <- optional_datetime(valid_to),
         :ok <- ordered_interval(from, to) do
      :ok
    end
  end

  defp optional_datetime(nil), do: {:ok, nil}

  defp optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _other -> {:error, :invalid_validity_interval}
    end
  end

  defp optional_datetime(_value), do: {:error, :invalid_validity_interval}
  defp ordered_interval(nil, _to), do: :ok
  defp ordered_interval(_from, nil), do: :ok

  defp ordered_interval(from, to) do
    if DateTime.compare(from, to) == :lt, do: :ok, else: {:error, :invalid_validity_interval}
  end

  defp known_by?(record, known_at) do
    case DateTime.from_iso8601(record["recorded_at"]) do
      {:ok, recorded_at, 0} -> DateTime.compare(recorded_at, known_at) in [:lt, :eq]
      _other -> false
    end
  end

  defp valid_at?(record, valid_at) do
    after_start?(record["valid_from"], valid_at) and before_end?(record["valid_to"], valid_at)
  end

  defp after_start?(nil, _valid_at), do: true

  defp after_start?(value, valid_at) do
    case DateTime.from_iso8601(value) do
      {:ok, from, 0} -> DateTime.compare(from, valid_at) in [:lt, :eq]
      _other -> false
    end
  end

  defp before_end?(nil, _valid_at), do: true

  defp before_end?(value, valid_at) do
    case DateTime.from_iso8601(value) do
      {:ok, to, 0} -> DateTime.compare(valid_at, to) == :lt
      _other -> false
    end
  end

  defp decode_tag("hmac-sha256:" <> hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, tag} when byte_size(tag) == 32 -> {:ok, tag}
      _other -> {:error, :invalid_integrity_tag}
    end
  end

  defp decode_tag(_value), do: {:error, :missing_integrity_tag}
  defp encode_tag(tag), do: "hmac-sha256:" <> Base.encode16(tag, case: :lower)

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp stringify(value), do: value
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp lock(claim_id, fun) do
    resource = {__MODULE__, Path.expand(Memory.root()), claim_id}
    :global.trans({resource, self()}, fun, [node()], :infinity)
  end
end
