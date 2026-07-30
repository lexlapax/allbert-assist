defmodule AllbertAssist.Search.Control do
  @moduledoc """
  Content-free recovery authority for one confirmed Search projection purge.

  This is a plain filesystem context because atomic manifest replacement is the
  durable state machine. A process would add no authority and would make crash
  recovery depend on supervision order.
  """

  alias AllbertAssist.Settings.KeyCustody

  @domain "allbert.search.purge-preview.v1"
  @key_version 1
  @schema_version 1
  @filename "search-control.json"
  @phases ~w[pending connections_closed files_replaced verified complete]
  @target_kinds ~w[source_ids source_class all]
  @fields ~w[schema_version phase policy_epoch target_kind target_ids source_classes expected_eligibility_epoch preview_binding key_ref key_version confirmation_id attempt_id attempt_count last_error]

  @doc "Return the verified purge manifest, or a complete initial state when absent."
  def load(root) when is_binary(root) do
    path = path(root)

    case File.read(path) do
      {:ok, bytes} -> decode_and_validate(bytes)
      {:error, :enoent} -> {:ok, initial_manifest()}
      {:error, reason} -> {:error, {:purge_control_read_failed, reason}}
    end
  end

  @doc "True only while a validated purge attempt has not completed."
  def incomplete?(%{"phase" => phase}), do: phase != "complete"

  @doc "Normalize the closed, content-free target shape."
  def normalize_target(params) when is_map(params) do
    kind = value(params, :target_kind)
    ids = value(params, :target_ids, [])
    classes = value(params, :source_classes, [])

    with {:ok, kind} <- target_kind(kind),
         {:ok, ids} <- target_ids(kind, ids),
         {:ok, classes} <- source_classes(kind, classes) do
      {:ok, %{"target_kind" => kind, "target_ids" => ids, "source_classes" => classes}}
    end
  end

  def normalize_target(_params), do: {:error, :invalid_purge_target}

  @doc "Bind one target and exact managed-file/generation scope without content."
  def bind_preview(target, scope) when is_map(target) and is_map(scope) do
    fields = binding_fields(target, scope)

    with {:ok, hmac} <- KeyCustody.system_hmac(@domain, fields, @key_version) do
      {:ok,
       %{
         target_kind: target["target_kind"],
         target_ids: target["target_ids"],
         source_classes: target["source_classes"],
         expected_eligibility_epoch: scope.eligibility_epoch,
         managed_files: scope.managed_files,
         generation_ids: scope.generation_ids,
         preview_binding: encode_tag(hmac.tag),
         key_ref: hmac.key_ref,
         key_version: hmac.key_version
       }}
    else
      {:error, _reason} -> {:error, :search_integrity_key_unavailable}
    end
  end

  @doc "Persist pending before any destructive work, or resume the exact attempt."
  def begin(root, params, scope, confirmation_id) do
    with {:ok, target} <- normalize_target(params),
         {:ok, current} <- load(root),
         {:ok, manifest} <- begin_manifest(current, target, params, scope, confirmation_id),
         :ok <- write(root, manifest) do
      {:ok, manifest}
    end
  end

  @doc "Advance exactly one durable recovery phase."
  def transition(root, manifest, expected_phase, next_phase)
      when expected_phase in @phases and next_phase in @phases do
    with true <- manifest["phase"] == expected_phase || {:error, :purge_phase_changed},
         {:ok, current} <- load(root),
         true <- same_attempt?(manifest, current) || {:error, :purge_attempt_changed},
         true <- current["phase"] == expected_phase || {:error, :purge_phase_changed},
         updated <- current |> Map.put("phase", next_phase) |> Map.put("last_error", nil),
         :ok <- write(root, updated) do
      {:ok, updated}
    end
  end

  @doc "Record a safe retry diagnostic without inventing an error phase."
  def record_error(root, manifest, reason) do
    with {:ok, current} <- load(root),
         true <- same_attempt?(manifest, current) || {:error, :purge_attempt_changed},
         updated <-
           current
           |> Map.update!("attempt_count", &(&1 + 1))
           |> Map.put("last_error", error_code(reason)),
         :ok <- write(root, updated) do
      {:ok, updated}
    end
  end

  defp begin_manifest(%{"phase" => "complete"} = current, target, params, scope, confirmation_id) do
    with :ok <- expected_epoch(params, scope.eligibility_epoch),
         :ok <- verify_binding(target, params, scope),
         {:ok, confirmation_id} <- required_string(confirmation_id) do
      {:ok,
       %{
         "schema_version" => @schema_version,
         "phase" => "pending",
         "policy_epoch" => current["policy_epoch"] + 1,
         "target_kind" => target["target_kind"],
         "target_ids" => target["target_ids"],
         "source_classes" => target["source_classes"],
         "expected_eligibility_epoch" => scope.eligibility_epoch,
         "preview_binding" => value(params, :preview_binding),
         "key_ref" => value(params, :key_ref),
         "key_version" => value(params, :key_version),
         "confirmation_id" => confirmation_id,
         "attempt_id" => uuid7(),
         "attempt_count" => 1,
         "last_error" => nil
       }}
    end
  end

  defp begin_manifest(current, target, params, _scope, confirmation_id) do
    requested = %{
      "target_kind" => target["target_kind"],
      "target_ids" => target["target_ids"],
      "source_classes" => target["source_classes"],
      "expected_eligibility_epoch" => value(params, :expected_eligibility_epoch),
      "preview_binding" => value(params, :preview_binding),
      "key_ref" => value(params, :key_ref),
      "key_version" => value(params, :key_version),
      "confirmation_id" => confirmation_id
    }

    if Enum.all?(requested, fn {key, expected} -> current[key] == expected end),
      do: {:ok, current},
      else: {:error, :search_purge_in_progress}
  end

  defp verify_binding(target, params, scope) do
    with {:ok, tag} <- decode_tag(value(params, :preview_binding)),
         {:ok, true} <-
           KeyCustody.verify_system_hmac(
             @domain,
             binding_fields(target, scope),
             tag,
             value(params, :key_ref),
             value(params, :key_version)
           ) do
      :ok
    else
      {:ok, false} -> {:error, :stale_purge_preview}
      {:error, _reason} -> {:error, :stale_purge_preview}
    end
  end

  defp binding_fields(target, scope) do
    [
      "target_kind:#{target["target_kind"]}",
      "target_ids:#{Enum.join(target["target_ids"], ",")}",
      "source_classes:#{Enum.join(target["source_classes"], ",")}",
      "eligibility_epoch:#{scope.eligibility_epoch}",
      "managed_files:#{Enum.join(scope.managed_files, ",")}",
      "generation_ids:#{Enum.join(scope.generation_ids, ",")}",
      "policy_epoch:#{scope.policy_epoch}"
    ]
  end

  defp expected_epoch(params, current) do
    if value(params, :expected_eligibility_epoch) == current,
      do: :ok,
      else: {:error, :stale_purge_preview}
  end

  defp decode_and_validate(bytes) do
    with {:ok, %{} = manifest} <- Jason.decode(bytes),
         :ok <- validate_manifest(manifest) do
      {:ok, manifest}
    else
      {:ok, _other} -> {:error, :invalid_purge_control_shape}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_purge_control_json}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_manifest(manifest) do
    with :ok <- validate_manifest_shape(manifest),
         :ok <- validate_manifest_target(manifest),
         :ok <- validate_manifest_counters(manifest),
         :ok <- validate_phase_fields(manifest) do
      :ok
    end
  end

  defp validate_manifest_shape(manifest) do
    with true <-
           Enum.sort(Map.keys(manifest)) == Enum.sort(@fields) ||
             {:error, :invalid_purge_control_fields},
         true <-
           manifest["schema_version"] == @schema_version ||
             {:error, :unsupported_purge_control_schema},
         true <- manifest["phase"] in @phases || {:error, :invalid_purge_control_phase} do
      :ok
    end
  end

  defp validate_manifest_target(manifest) do
    with true <-
           manifest["target_kind"] in @target_kinds || {:error, :invalid_purge_control_target},
         true <-
           valid_sorted_strings?(manifest["target_ids"]) ||
             {:error, :invalid_purge_control_target},
         true <-
           valid_sorted_strings?(manifest["source_classes"]) ||
             {:error, :invalid_purge_control_target} do
      :ok
    end
  end

  defp validate_manifest_counters(manifest) do
    with true <- non_negative?(manifest["policy_epoch"]) || {:error, :invalid_purge_control_epoch},
         true <-
           non_negative?(manifest["expected_eligibility_epoch"]) ||
             {:error, :invalid_purge_control_epoch},
         true <-
           (is_integer(manifest["attempt_count"]) and manifest["attempt_count"] >= 0) ||
             {:error, :invalid_purge_control_attempt} do
      :ok
    end
  end

  defp validate_phase_fields(%{"phase" => "complete"}), do: :ok

  defp validate_phase_fields(manifest) do
    with {:ok, _binding} <- required_string(manifest["preview_binding"]),
         {:ok, _key_ref} <- required_string(manifest["key_ref"]),
         true <- manifest["key_version"] == @key_version || {:error, :invalid_purge_control_key},
         {:ok, _confirmation} <- required_string(manifest["confirmation_id"]),
         {:ok, _attempt} <- required_string(manifest["attempt_id"]) do
      :ok
    end
  end

  defp initial_manifest do
    %{
      "schema_version" => @schema_version,
      "phase" => "complete",
      "policy_epoch" => 0,
      "target_kind" => "all",
      "target_ids" => [],
      "source_classes" => [],
      "expected_eligibility_epoch" => 0,
      "preview_binding" => nil,
      "key_ref" => nil,
      "key_version" => @key_version,
      "confirmation_id" => nil,
      "attempt_id" => nil,
      "attempt_count" => 0,
      "last_error" => nil
    }
  end

  defp target_kind(kind) when kind in [:source_ids, "source_ids"], do: {:ok, "source_ids"}
  defp target_kind(kind) when kind in [:source_class, "source_class"], do: {:ok, "source_class"}
  defp target_kind(kind) when kind in [:all, "all"], do: {:ok, "all"}
  defp target_kind(_kind), do: {:error, :invalid_purge_target}

  defp target_ids("source_ids", ids) do
    with {:ok, normalized} <- normalized_strings(ids, false),
         true <- length(normalized) <= 100 || {:error, :too_many_purge_targets} do
      {:ok, normalized}
    end
  end

  defp target_ids(_kind, []), do: {:ok, []}
  defp target_ids(_kind, _ids), do: {:error, :invalid_purge_target}

  defp source_classes("source_class", classes) do
    with {:ok, values} <- normalized_strings(classes, false),
         true <- values == ["conversation"] || {:error, :invalid_purge_target} do
      {:ok, values}
    end
  end

  defp source_classes(_kind, []), do: {:ok, []}
  defp source_classes(_kind, _classes), do: {:error, :invalid_purge_target}

  defp normalized_strings(values, allow_empty?) when is_list(values) do
    normalized =
      values
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    if length(normalized) == length(values) and (allow_empty? or normalized != []),
      do: {:ok, normalized},
      else: {:error, :invalid_purge_target}
  end

  defp normalized_strings(_values, _allow_empty?), do: {:error, :invalid_purge_target}

  defp valid_sorted_strings?(values) when is_list(values),
    do:
      values == Enum.sort(Enum.uniq(values)) and Enum.all?(values, &(is_binary(&1) and &1 != ""))

  defp valid_sorted_strings?(_values), do: false
  defp non_negative?(value), do: is_integer(value) and value >= 0

  defp same_attempt?(left, right), do: left["attempt_id"] == right["attempt_id"]

  defp write(root, manifest) do
    path = path(root)
    tmp = path <> ".tmp-" <> uuid7()
    bytes = Jason.encode_to_iodata!(manifest, pretty: true)

    with :ok <- File.mkdir_p(root),
         :ok <- File.write(tmp, bytes, [:binary, :exclusive]),
         {:ok, io} <- File.open(tmp, [:read, :binary]),
         :ok <- sync_and_close(io),
         :ok <- File.rename(tmp, path),
         :ok <- sync_directory(root) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:purge_control_write_failed, reason}}
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

  defp path(root), do: Path.join(root, @filename)

  defp encode_tag(tag), do: "hmac-sha256:" <> Base.url_encode64(tag, padding: false)

  defp decode_tag("hmac-sha256:" <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, tag} when byte_size(tag) == 32 -> {:ok, tag}
      _other -> {:error, :invalid_purge_binding}
    end
  end

  defp decode_tag(_value), do: {:error, :invalid_purge_binding}

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp required_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_purge_attempt}
      string -> {:ok, string}
    end
  end

  defp required_string(_value), do: {:error, :invalid_purge_attempt}

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "search_purge_failed"

  defp uuid7 do
    timestamp_ms = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _unused::6>> = :crypto.strong_rand_bytes(10)

    <<timestamp_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp format_uuid(
         <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
           e::binary-size(12)>>
       ),
       do: Enum.join([a, b, c, d, e], "-")
end
