defmodule AllbertAssist.Pack.Canonical do
  @moduledoc """
  Strict kernel-local canonical encoding for immutable Pack snapshots.

  The encoder accepts only validated JSON authority values. It never falls back
  to `inspect/1`, and therefore cannot turn an unknown runtime term into stable
  authority bytes accidentally.
  """

  alias AllbertAssist.Pack.{ActionBinding, Compatibility, CompatibilityAlias}
  alias AllbertAssist.Pack.{ChildSpecProjection, CompatibilityDiagnostic, Contribution}
  alias AllbertAssist.Pack.{Descriptor, Order, Owner, OwnerRef, Row, RowSchemas, Target}
  alias AllbertAssist.Pack.{PathSegment, ValidationDiagnostic}
  alias AllbertAssist.Pack.Registry.{Candidate, Snapshot}
  alias AllbertAssist.Pack.RowSchemas.Input

  @snapshot_domain "allbert.pack.snapshot.v1\0"
  @contribution_alias_domain "allbert.pack.contribution.alias.authority.v2\0"
  @contribution_callbacks_domain "allbert.pack.contribution.callbacks.v1\0"
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @module_string_pattern ~r/\A[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z/
  @capability_fields [
    :app_id,
    :confirmation,
    :execution_mode,
    :exposure,
    :notes,
    :permission,
    :plugin_id,
    :resumable?,
    :retry_safety,
    :skill_backed?
  ]
  @compatibility_diagnostic_codes [
    :legacy_registry,
    :disabled_plugin,
    :deprecated_alias,
    :child_spec,
    :collision
  ]
  @candidate_fields [
    :__struct__,
    :schema_version,
    :contributions,
    :action_bindings,
    :compatibility_aliases,
    :compatibility_diagnostics
  ]
  @snapshot_fields [
    :__struct__,
    :schema_version,
    :publication,
    :behavior_digest,
    :contributions,
    :effective_actions,
    :compatibility_aliases,
    :compatibility_diagnostics
  ]

  @spec build_snapshot(Candidate.t(), :shadow | :authoritative) ::
          {:ok, Snapshot.t()} | {:error, [ValidationDiagnostic.t()]}
  def build_snapshot(%Candidate{} = candidate, publication)
      when publication in [:shadow, :authoritative] do
    with :ok <- validate_candidate_envelope(candidate),
         {:ok, projection} <- behavior_projection(candidate),
         {:ok, bytes} <- encode_json(projection) do
      digest = sha256(@snapshot_domain <> bytes)

      {:ok,
       %Snapshot{
         schema_version: 1,
         publication: publication,
         behavior_digest: digest,
         contributions: sort_contributions(candidate.contributions),
         effective_actions: sort_actions(candidate.action_bindings),
         compatibility_aliases: sort_aliases(candidate.compatibility_aliases),
         compatibility_diagnostics: sort_diagnostics(candidate.compatibility_diagnostics)
       }}
    end
  end

  def build_snapshot(candidate, publication) when publication in [:shadow, :authoritative] do
    {:error,
     [
       validation_diagnostic(
         :invalid_type,
         [],
         %{expected: "Candidate", actual: value_kind(candidate)}
       )
     ]}
  end

  def build_snapshot(_candidate, _publication),
    do: canonicalization_error("publication")

  @spec snapshot_bytes(Snapshot.t()) :: {:ok, binary()} | {:error, term()}
  def snapshot_bytes(%Snapshot{} = snapshot) do
    with :ok <- validate_snapshot_envelope(snapshot),
         {:ok, projection} <- behavior_projection(snapshot),
         {:ok, bytes} <- encode_json(projection),
         :ok <- validate_snapshot_digest(snapshot, bytes) do
      {:ok, bytes}
    end
  end

  def snapshot_bytes(snapshot) do
    {:error,
     [
       validation_diagnostic(
         :invalid_type,
         [],
         %{expected: "Snapshot", actual: value_kind(snapshot)}
       )
     ]}
  end

  @doc false
  @spec contribution_alias_authority(Contribution.t(), Contribution.t()) ::
          {:ok, %{projection: map(), authority_sha256: String.t()}} | {:error, term()}
  def contribution_alias_authority(%Contribution{} = source, %Contribution{} = target) do
    with {:ok, source_rows} <- contribution_alias_rows(source),
         {:ok, target_rows} <- contribution_alias_rows(target),
         true <- authority_subset?(source_rows, target_rows),
         true <- source.compatibility.trust == target.compatibility.trust,
         true <- source.compatibility.enabled == target.compatibility.enabled,
         {:ok, callbacks_bytes} <- encode_json(source_rows) do
      callbacks_sha256 = sha256(@contribution_callbacks_domain <> callbacks_bytes)

      projection = %{
        "kind" => "contribution_alias_transition",
        "source_implementation_module" => module_string(source.implementation_module),
        "target_implementation_module" => module_string(target.implementation_module),
        "trust" => Atom.to_string(source.compatibility.trust),
        "enabled" => source.compatibility.enabled,
        "callbacks_sha256" => callbacks_sha256
      }

      with {:ok, authority_bytes} <- encode_json(projection) do
        {:ok,
         %{
           projection: projection,
           authority_sha256: sha256(@contribution_alias_domain <> authority_bytes)
         }}
      end
    else
      {:error, _diagnostics} = error -> error
      _mismatch -> canonicalization_error("contribution_alias_authority")
    end
  end

  def contribution_alias_authority(_source, _target),
    do: canonicalization_error("contribution_alias_authority")

  defp validate_candidate_envelope(%Candidate{} = candidate) do
    keys = Map.keys(candidate)
    missing_fields = @candidate_fields -- keys
    unknown_fields = keys -- @candidate_fields

    cond do
      missing_fields != [] ->
        {:error, missing_field_diagnostics(missing_fields)}

      unknown_fields != [] ->
        {:error, unknown_field_diagnostics(unknown_fields)}

      true ->
        validate_candidate_fields(candidate)
    end
  end

  defp validate_snapshot_envelope(%Snapshot{} = snapshot) do
    keys = Map.keys(snapshot)
    missing_fields = @snapshot_fields -- keys
    unknown_fields = keys -- @snapshot_fields

    cond do
      missing_fields != [] ->
        {:error, missing_field_diagnostics(missing_fields)}

      unknown_fields != [] ->
        {:error, unknown_field_diagnostics(unknown_fields)}

      true ->
        validate_snapshot_fields(snapshot)
    end
  end

  defp validate_snapshot_fields(%Snapshot{schema_version: 1, publication: publication})
       when publication not in [:shadow, :authoritative] do
    {:error,
     [
       validation_diagnostic(
         :invalid_value,
         [field_segment("publication")],
         %{reason: :unsupported_publication}
       )
     ]}
  end

  defp validate_snapshot_fields(%Snapshot{
         schema_version: 1,
         behavior_digest: behavior_digest
       })
       when not is_binary(behavior_digest) do
    {:error,
     [
       validation_diagnostic(
         :invalid_type,
         [field_segment("behavior_digest")],
         %{expected: "lowercase_sha256", actual: value_kind(behavior_digest)}
       )
     ]}
  end

  defp validate_snapshot_fields(
         %Snapshot{
           schema_version: 1,
           behavior_digest: behavior_digest
         } = snapshot
       ) do
    if lowercase_sha256?(behavior_digest) do
      validate_snapshot_collections(snapshot)
    else
      {:error,
       [
         validation_diagnostic(
           :invalid_value,
           [field_segment("behavior_digest")],
           %{reason: :lowercase_sha256_required}
         )
       ]}
    end
  end

  defp validate_snapshot_fields(%Snapshot{schema_version: schema_version})
       when is_integer(schema_version) and schema_version >= 0 do
    {:error,
     [
       validation_diagnostic(
         :unsupported_schema_version,
         [field_segment("schema_version")],
         %{expected: 1, actual: schema_version}
       )
     ]}
  end

  defp validate_snapshot_fields(%Snapshot{schema_version: schema_version})
       when is_integer(schema_version) do
    {:error,
     [
       validation_diagnostic(
         :invalid_value,
         [field_segment("schema_version")],
         %{reason: :non_neg_integer_required}
       )
     ]}
  end

  defp validate_snapshot_fields(%Snapshot{schema_version: schema_version}) do
    {:error,
     [
       validation_diagnostic(
         :invalid_type,
         [field_segment("schema_version")],
         %{expected: "non_neg_integer", actual: value_kind(schema_version)}
       )
     ]}
  end

  defp validate_snapshot_collections(%Snapshot{} = snapshot) do
    fields = [
      {"contributions", snapshot.contributions},
      {"effective_actions", snapshot.effective_actions},
      {"compatibility_aliases", snapshot.compatibility_aliases},
      {"compatibility_diagnostics", snapshot.compatibility_diagnostics}
    ]

    case Enum.find(fields, fn {_field, value} -> not is_list(value) end) do
      {field, value} ->
        {:error,
         [
           validation_diagnostic(
             :invalid_type,
             [field_segment(field)],
             %{expected: "list", actual: value_kind(value)}
           )
         ]}

      nil ->
        candidate = %Candidate{
          schema_version: 1,
          contributions: snapshot.contributions,
          action_bindings: snapshot.effective_actions,
          compatibility_aliases: snapshot.compatibility_aliases,
          compatibility_diagnostics: snapshot.compatibility_diagnostics
        }

        case validate_candidate_fields(candidate) do
          :ok -> :ok
          {:error, diagnostics} -> {:error, Enum.map(diagnostics, &snapshot_diagnostic/1)}
        end
    end
  end

  defp snapshot_diagnostic(%ValidationDiagnostic{path: path} = diagnostic) do
    translated =
      Enum.map(path, fn
        %PathSegment{kind: :field, value: "action_bindings"} = segment ->
          %{segment | value: "effective_actions"}

        segment ->
          segment
      end)

    %{diagnostic | path: translated}
  end

  defp validate_snapshot_digest(%Snapshot{behavior_digest: actual}, bytes) do
    expected = sha256(@snapshot_domain <> bytes)

    if actual == expected do
      :ok
    else
      {:error,
       [
         validation_diagnostic(
           :digest_mismatch,
           [field_segment("behavior_digest")],
           %{expected: expected, actual: actual}
         )
       ]}
    end
  end

  defp validate_candidate_fields(%Candidate{
         schema_version: 1,
         contributions: contributions,
         action_bindings: actions,
         compatibility_aliases: aliases,
         compatibility_diagnostics: diagnostics
       })
       when is_list(contributions) and is_list(actions) and is_list(aliases) and
              is_list(diagnostics) do
    with :ok <- validate_collection_types(contributions, "contributions", Contribution),
         :ok <- validate_collection_types(actions, "action_bindings", ActionBinding),
         :ok <- validate_collection_types(aliases, "compatibility_aliases", CompatibilityAlias),
         :ok <-
           validate_collection_types(
             diagnostics,
             "compatibility_diagnostics",
             CompatibilityDiagnostic
           ),
         :ok <- validate_contribution_owner_ids(contributions),
         :ok <- validate_contribution_records(contributions),
         :ok <- validate_contributions(contributions),
         :ok <- validate_unique_contribution_identities(contributions),
         :ok <- validate_unique_contribution_orders(contributions),
         :ok <- validate_row_uniqueness(contributions),
         :ok <- validate_actions(actions),
         :ok <- validate_diagnostics(diagnostics),
         :ok <- validate_cross_record_semantics(contributions, actions, diagnostics),
         :ok <- validate_aliases(contributions, actions, aliases),
         :ok <- validate_action_integrity(contributions, actions, aliases) do
      :ok
    end
  end

  defp validate_candidate_fields(%Candidate{schema_version: 1} = candidate) do
    fields = [
      {"contributions", candidate.contributions},
      {"action_bindings", candidate.action_bindings},
      {"compatibility_aliases", candidate.compatibility_aliases},
      {"compatibility_diagnostics", candidate.compatibility_diagnostics}
    ]

    case Enum.find(fields, fn {_field, value} -> not is_list(value) end) do
      {field, value} ->
        {:error,
         [
           validation_diagnostic(
             :invalid_type,
             [field_segment(field)],
             %{expected: "list", actual: value_kind(value)}
           )
         ]}

      nil ->
        canonicalization_error("candidate")
    end
  end

  defp validate_candidate_fields(%Candidate{schema_version: schema_version})
       when is_integer(schema_version) and schema_version >= 0 do
    {:error,
     [
       validation_diagnostic(
         :unsupported_schema_version,
         [field_segment("schema_version")],
         %{expected: 1, actual: schema_version}
       )
     ]}
  end

  defp validate_candidate_fields(%Candidate{schema_version: schema_version})
       when is_integer(schema_version) do
    {:error,
     [
       validation_diagnostic(
         :invalid_value,
         [field_segment("schema_version")],
         %{reason: :non_neg_integer_required}
       )
     ]}
  end

  defp validate_candidate_fields(%Candidate{schema_version: schema_version}) do
    {:error,
     [
       validation_diagnostic(
         :invalid_type,
         [field_segment("schema_version")],
         %{expected: "non_neg_integer", actual: value_kind(schema_version)}
       )
     ]}
  end

  defp unknown_field_diagnostics(fields) do
    fields
    |> Enum.map(&field_name/1)
    |> Enum.sort()
    |> Enum.map(fn field ->
      %ValidationDiagnostic{
        schema_version: 1,
        code: :unknown_field,
        path: [%PathSegment{schema_version: 1, kind: :field, value: field}],
        owner: nil,
        detail: %{field: field}
      }
    end)
  end

  defp missing_field_diagnostics(fields) do
    fields
    |> Enum.map(&field_name/1)
    |> Enum.sort()
    |> Enum.map(fn field ->
      %ValidationDiagnostic{
        schema_version: 1,
        code: :missing_field,
        path: [%PathSegment{schema_version: 1, kind: :field, value: field}],
        owner: nil,
        detail: %{field: field}
      }
    end)
  end

  defp field_name(field) when is_atom(field), do: Atom.to_string(field)
  defp field_name(field) when is_binary(field), do: field
  defp field_name(_field), do: "<non-string-field>"

  defp value_kind(value) when is_atom(value), do: "atom"
  defp value_kind(value) when is_integer(value), do: "integer"
  defp value_kind(value) when is_float(value), do: "float"
  defp value_kind(value) when is_binary(value), do: "string"
  defp value_kind(value) when is_list(value), do: "list"
  defp value_kind(value) when is_map(value), do: "map"
  defp value_kind(value) when is_tuple(value), do: "tuple"
  defp value_kind(value) when is_function(value), do: "function"
  defp value_kind(value) when is_pid(value), do: "pid"
  defp value_kind(value) when is_port(value), do: "port"
  defp value_kind(value) when is_reference(value), do: "reference"
  defp value_kind(_value), do: "term"

  defp validate_collection_types(values, field, module) do
    case Enum.find_index(values, &(not is_struct(&1, module))) do
      nil ->
        :ok

      index ->
        {:error,
         [
           validation_diagnostic(
             :invalid_type,
             [field_segment(field), index_segment(index)],
             %{
               expected: module |> Module.split() |> List.last(),
               actual: value_kind(Enum.at(values, index))
             }
           )
         ]}
    end
  end

  defp validate_unique_contribution_orders(contributions) do
    contributions
    |> Enum.filter(fn
      %Contribution{owner: %Owner{}, owner_order: %Order{}} -> true
      _contribution -> false
    end)
    |> sort_contributions()
    |> Enum.reduce_while(MapSet.new(), fn contribution, seen ->
      key = {contribution.owner_order.namespace, contribution.owner_order.value}

      if MapSet.member?(seen, key) do
        identity =
          Atom.to_string(contribution.owner_order.namespace) <>
            ":" <> to_string(contribution.owner_order.value)

        owner = %OwnerRef{
          schema_version: 1,
          kind: contribution.owner.kind,
          id: contribution.owner.id
        }

        {:halt,
         {:error,
          [
            validation_diagnostic(
              :duplicate_order,
              [
                field_segment("contributions"),
                identity_segment(contribution.owner.id),
                field_segment("owner_order")
              ],
              %{identity: identity},
              owner
            )
          ]}}
      else
        {:cont, MapSet.put(seen, key)}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, _diagnostics} = error -> error
    end
  end

  defp validate_unique_contribution_identities(contributions) do
    contributions
    |> sort_contributions()
    |> Enum.reduce_while(MapSet.new(), fn
      %Contribution{owner: %Owner{} = owner}, seen ->
        key = owner.id

        if MapSet.member?(seen, key) do
          identity = Atom.to_string(owner.kind) <> ":" <> owner.id

          {:halt,
           {:error,
            [
              validation_diagnostic(
                :duplicate_identity,
                [field_segment("contributions"), identity_segment(owner.id)],
                %{identity: identity},
                owner_ref(owner)
              )
            ]}}
        else
          {:cont, MapSet.put(seen, key)}
        end

      _contribution, seen ->
        {:cont, seen}
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, _diagnostics} = error -> error
    end
  end

  defp validate_row_uniqueness(contributions) do
    active_entries =
      contributions
      |> Enum.reject(&deprecated_contribution?/1)
      |> row_entries()

    deprecated_entries =
      contributions
      |> Enum.filter(&deprecated_contribution?/1)
      |> row_entries()

    with :ok <- validate_unique_row_identities(active_entries),
         :ok <- validate_unique_row_orders(active_entries),
         :ok <- validate_unique_row_identities(deprecated_entries),
         :ok <- validate_unique_row_orders(deprecated_entries) do
      :ok
    end
  end

  defp deprecated_contribution?(%Contribution{
         compatibility: %Compatibility{kind: :deprecated_alias}
       }),
       do: true

  defp deprecated_contribution?(_contribution), do: false

  defp validate_unique_row_identities(entries) do
    entries
    |> Enum.sort_by(fn {contribution, row} ->
      {
        contribution.owner.id,
        atom_string(row.kind),
        atom_string(row.identity[:namespace]),
        row.identity[:value],
        row_sort_key(row)
      }
    end)
    |> Enum.reduce_while(MapSet.new(), fn {contribution, row}, seen ->
      key = {row.owner_id, row.kind, row.identity[:namespace], row.identity[:value]}

      if MapSet.member?(seen, key) do
        identity =
          Enum.join(
            [
              row.owner_id,
              Atom.to_string(row.kind),
              Atom.to_string(row.identity[:namespace]),
              row.identity[:value]
            ],
            ":"
          )

        {:halt,
         {:error,
          [
            validation_diagnostic(
              :duplicate_identity,
              row_path(contribution, row),
              %{identity: identity},
              owner_ref(contribution.owner)
            )
          ]}}
      else
        {:cont, MapSet.put(seen, key)}
      end
    end)
    |> set_or_error()
  end

  defp validate_unique_row_orders(entries) do
    entries
    |> Enum.reject(fn {_contribution, row} -> row.order[:namespace] == :alias_target end)
    |> Enum.sort_by(fn {contribution, row} ->
      {row_sort_key(row), contribution.owner.id, row.identity[:value]}
    end)
    |> Enum.reduce_while(MapSet.new(), fn {contribution, row}, seen ->
      key = {row.kind, row.order[:namespace], row.order[:value]}

      if MapSet.member?(seen, key) do
        identity =
          Enum.join(
            [
              Atom.to_string(row.kind),
              Atom.to_string(row.order[:namespace]),
              to_string(row.order[:value])
            ],
            ":"
          )

        {:halt,
         {:error,
          [
            validation_diagnostic(
              :duplicate_order,
              row_path(contribution, row),
              %{identity: identity},
              owner_ref(contribution.owner)
            )
          ]}}
      else
        {:cont, MapSet.put(seen, key)}
      end
    end)
    |> set_or_error()
  end

  defp row_entries(contributions) do
    for contribution <- sort_contributions(contributions),
        callback <- RowSchemas.callback_order(),
        row <- callback_rows(contribution, callback),
        is_struct(row, Row) do
      {contribution, row}
    end
  end

  defp callback_rows(%Contribution{callbacks: callbacks}, callback) when is_map(callbacks) do
    case Map.get(callbacks, callback, []) do
      rows when is_list(rows) -> rows
      _rows -> []
    end
  end

  defp callback_rows(_contribution, _callback), do: []

  defp set_or_error(%MapSet{}), do: :ok
  defp set_or_error({:error, _diagnostics} = error), do: error

  defp validate_contribution_records(contributions) do
    contributions
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {contribution, index}, :ok ->
      case validate_contribution_record(contribution, index) do
        :ok -> {:cont, :ok}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
  end

  defp validate_contribution_record(%Contribution{} = contribution, index) do
    base_path = contribution_base_path(contribution, index)

    with :ok <- validate_exact_struct_at(contribution, Contribution, base_path),
         :ok <-
           nested_schema_error(
             contribution.schema_version,
             base_path ++ [field_segment("schema_version")]
           ),
         :ok <- validate_owner_record(contribution.owner, base_path ++ [field_segment("owner")]),
         :ok <-
           validate_order_record(
             contribution.owner_order,
             base_path ++ [field_segment("owner_order")]
           ),
         :ok <-
           validate_compatibility_record(
             contribution.compatibility,
             base_path ++ [field_segment("compatibility")]
           ),
         :ok <- validate_callbacks_record(contribution, base_path ++ [field_segment("callbacks")]),
         :ok <- validate_contribution_semantics(contribution, base_path) do
      :ok
    end
  end

  defp contribution_base_path(%Contribution{owner: %Owner{id: id}}, _index)
       when is_binary(id) do
    [field_segment("contributions"), identity_segment(id)]
  end

  defp contribution_base_path(_contribution, index),
    do: [field_segment("contributions"), index_segment(index)]

  defp validate_owner_record(%Owner{} = owner, path) do
    with :ok <- validate_exact_struct_at(owner, Owner, path),
         :ok <-
           nested_schema_error(owner.schema_version, path ++ [field_segment("schema_version")]) do
      cond do
        owner.kind not in [:compiled_pack, :legacy_plugin, :declared_pack] ->
          invalid_value(path ++ [field_segment("kind")], :unsupported_owner_kind)

        not canonical_string?(owner.id) ->
          invalid_value(path ++ [field_segment("id")], :canonical_string_required)

        not is_nil(owner.application) and
            (not is_atom(owner.application) or owner.application in [true, false]) ->
          invalid_type_at(
            path ++ [field_segment("application")],
            "atom_or_nil",
            owner.application
          )

        true ->
          :ok
      end
    end
  end

  defp validate_owner_record(value, path), do: invalid_type_at(path, "Owner", value)

  defp validate_order_record(%Order{} = order, path) do
    with :ok <- validate_exact_struct_at(order, Order, path),
         :ok <-
           nested_schema_error(order.schema_version, path ++ [field_segment("schema_version")]) do
      cond do
        order.namespace not in [:compiled_pack, :legacy_plugin, :declared_pack] ->
          invalid_value(path ++ [field_segment("namespace")], :unsupported_order_namespace)

        not (is_integer(order.value) or is_binary(order.value)) ->
          invalid_type_at(
            path ++ [field_segment("value")],
            "non_neg_integer_or_string",
            order.value
          )

        true ->
          :ok
      end
    end
  end

  defp validate_order_record(value, path), do: invalid_type_at(path, "Order", value)

  defp validate_compatibility_record(%Compatibility{} = compatibility, path) do
    with :ok <- validate_exact_struct_at(compatibility, Compatibility, path),
         :ok <-
           nested_schema_error(
             compatibility.schema_version,
             path ++ [field_segment("schema_version")]
           ) do
      cond do
        compatibility.kind not in [:native, :legacy_plugin, :declared, :deprecated_alias] ->
          invalid_value(path ++ [field_segment("kind")], :unsupported_compatibility_kind)

        not is_nil(compatibility.legacy_id) and
            not canonical_string?(compatibility.legacy_id) ->
          invalid_value(path ++ [field_segment("legacy_id")], :canonical_string_or_nil_required)

        compatibility.trust not in [:trusted, :pending, :untrusted] ->
          invalid_value(path ++ [field_segment("trust")], :unsupported_trust)

        not is_boolean(compatibility.enabled) ->
          invalid_type_at(path ++ [field_segment("enabled")], "boolean", compatibility.enabled)

        is_nil(compatibility.alias_of) ->
          :ok

        true ->
          validate_target(compatibility.alias_of, path ++ [field_segment("alias_of")])
      end
    end
  end

  defp validate_compatibility_record(value, path),
    do: invalid_type_at(path, "Compatibility", value)

  defp validate_callbacks_record(%Contribution{callbacks: callbacks} = contribution, path)
       when is_map(callbacks) do
    expected = RowSchemas.callback_order()
    actual = Map.keys(callbacks)

    with :ok <- validate_callback_keys(expected, actual, path),
         :ok <- validate_callback_rows(expected, callbacks, contribution, path) do
      :ok
    end
  end

  defp validate_callbacks_record(%Contribution{callbacks: callbacks}, path),
    do: invalid_type_at(path, "map", callbacks)

  defp validate_callback_keys(expected, actual, path) do
    cond do
      missing = Enum.find(expected, &(&1 not in actual)) ->
        missing_field(path ++ [field_segment(Atom.to_string(missing))], Atom.to_string(missing))

      unknown =
          actual
          |> Enum.reject(&(&1 in expected))
          |> Enum.sort_by(&field_name/1)
          |> List.first() ->
        name = field_name(unknown)
        unknown_field(path ++ [field_segment(name)], name)

      true ->
        :ok
    end
  end

  defp validate_callback_rows(expected, callbacks, contribution, path) do
    Enum.reduce_while(expected, :ok, fn callback, :ok ->
      rows = Map.fetch!(callbacks, callback)
      callback_path = path ++ [field_segment(Atom.to_string(callback))]

      validate_callback_rows_for(rows, contribution, callback, callback_path)
    end)
  end

  defp validate_callback_rows_for(rows, contribution, callback, callback_path)
       when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {row, index}, :ok ->
      case validate_callback_row(contribution, callback, row, index, callback_path) do
        :ok -> {:cont, :ok}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> {:cont, :ok}
      {:error, _diagnostics} = error -> {:halt, error}
    end
  end

  defp validate_callback_rows_for(rows, _contribution, _callback, callback_path),
    do: {:halt, invalid_type_at(callback_path, "list", rows)}

  defp validate_callback_row(contribution, callback, %Row{} = row, index, callback_path) do
    path = callback_path ++ [index_segment(index)]
    expected_schema = RowSchemas.payload_schema_for!(callback)

    with :ok <- validate_exact_struct_at(row, Row, path),
         :ok <- nested_schema_error(row.schema_version, path ++ [field_segment("schema_version")]),
         :ok <-
           validate_callback_row_membership(
             contribution,
             callback,
             expected_schema,
             row,
             path
           ),
         :ok <- validate_callback_row_shape(row, path) do
      :ok
    end
  end

  defp validate_callback_row(_contribution, _callback, value, index, callback_path),
    do: invalid_type_at(callback_path ++ [index_segment(index)], "Row", value)

  defp validate_callback_row_membership(contribution, callback, expected_schema, row, path) do
    cond do
      row.kind != callback ->
        invalid_value(path ++ [field_segment("kind")], :callback_container_mismatch)

      callback == :settings_migrations ->
        invalid_value(path, :reserved_callback)

      row.payload_schema != expected_schema ->
        invalid_value(path ++ [field_segment("payload_schema")], :callback_schema_mismatch)

      row.owner_id != contribution.owner.id ->
        owner_mismatch(
          path ++ [field_segment("owner_id")],
          contribution.owner.id,
          row.owner_id,
          owner_ref(contribution.owner)
        )

      true ->
        :ok
    end
  end

  defp validate_callback_row_shape(row, path) do
    cond do
      not exact_identity?(row.identity) ->
        invalid_type_at(path ++ [field_segment("identity")], "identity", row.identity)

      not exact_order?(row.order) ->
        invalid_type_at(path ++ [field_segment("order")], "order", row.order)

      not is_map(row.payload) ->
        invalid_type_at(path ++ [field_segment("payload")], "map", row.payload)

      not (is_map(row.source_authority) or is_nil(row.source_authority)) ->
        invalid_type_at(
          path ++ [field_segment("source_authority")],
          "map_or_nil",
          row.source_authority
        )

      not is_nil(row.m0_payload_sha256) and not lowercase_sha256?(row.m0_payload_sha256) ->
        invalid_value(path ++ [field_segment("m0_payload_sha256")], :lowercase_sha256_required)

      true ->
        :ok
    end
  end

  defp exact_identity?(%{namespace: namespace, value: value} = identity)
       when map_size(identity) == 2 and is_atom(namespace) and namespace not in [nil, true, false],
       do: canonical_string?(value)

  defp exact_identity?(_identity), do: false

  defp exact_order?(%{namespace: namespace, value: value} = order)
       when map_size(order) == 2 and is_atom(namespace) and namespace not in [nil, true, false] do
    (is_integer(value) and value >= 0) or canonical_string?(value)
  end

  defp exact_order?(_order), do: false

  defp validate_contribution_semantics(
         %Contribution{owner: %Owner{kind: :compiled_pack}} = contribution,
         path
       ) do
    validate_compiled_contribution(contribution, path)
  end

  defp validate_contribution_semantics(
         %Contribution{owner: %Owner{kind: :legacy_plugin}} = contribution,
         path
       ) do
    validate_legacy_contribution(contribution, path)
  end

  defp validate_contribution_semantics(
         %Contribution{owner: %Owner{kind: :declared_pack}} = contribution,
         path
       ) do
    validate_declared_contribution(contribution, path)
  end

  defp validate_compiled_contribution(%Contribution{} = contribution, path) do
    owner = contribution.owner
    owner_reference = owner_ref(owner)

    with :ok <- validate_required_module(contribution, path),
         :ok <-
           validate_descriptor_record(
             contribution.descriptor,
             path ++ [field_segment("descriptor")]
           ),
         :ok <-
           require_value(
             contribution.source_lane,
             :native,
             path ++ [field_segment("source_lane")],
             :owner_lane_mismatch
           ),
         :ok <-
           require_value(
             contribution.owner_order.namespace,
             :compiled_pack,
             path ++ [field_segment("owner_order"), field_segment("namespace")],
             :owner_order_mismatch
           ),
         :ok <-
           require_non_neg_integer(
             contribution.owner_order.value,
             path ++ [field_segment("owner_order"), field_segment("value")]
           ),
         :ok <-
           require_value(
             contribution.compatibility.kind,
             :native,
             path ++ [field_segment("compatibility"), field_segment("kind")],
             :owner_compatibility_mismatch
           ),
         :ok <-
           require_nil(
             contribution.compatibility.legacy_id,
             path ++ [field_segment("compatibility"), field_segment("legacy_id")],
             :legacy_id_forbidden
           ),
         :ok <-
           require_nil(
             contribution.compatibility.alias_of,
             path ++ [field_segment("compatibility"), field_segment("alias_of")],
             :alias_target_forbidden
           ),
         :ok <-
           require_value(
             contribution.compatibility.trust,
             :trusted,
             path ++ [field_segment("compatibility"), field_segment("trust")],
             :signed_pack_trust_required
           ),
         :ok <-
           require_value(
             contribution.compatibility.enabled,
             true,
             path ++ [field_segment("compatibility"), field_segment("enabled")],
             :signed_pack_must_be_enabled
           ) do
      descriptor = contribution.descriptor

      cond do
        is_nil(owner.application) ->
          invalid_value(
            path ++ [field_segment("owner"), field_segment("application")],
            :application_required,
            owner_reference
          )

        owner.id != descriptor.id ->
          owner_mismatch(
            path ++ [field_segment("descriptor"), field_segment("id")],
            owner.id,
            descriptor.id,
            owner_reference
          )

        owner.application != descriptor.application ->
          owner_mismatch(
            path ++ [field_segment("owner"), field_segment("application")],
            Atom.to_string(descriptor.application),
            atom_string(owner.application),
            owner_reference
          )

        contribution.owner_order.value != descriptor.registry_order ->
          owner_mismatch(
            path ++ [field_segment("owner_order"), field_segment("value")],
            to_string(descriptor.registry_order),
            to_string(contribution.owner_order.value),
            owner_reference
          )

        true ->
          :ok
      end
    end
  end

  defp validate_legacy_contribution(%Contribution{} = contribution, path) do
    owner = contribution.owner
    owner_reference = owner_ref(owner)

    with :ok <- validate_required_module(contribution, path),
         :ok <-
           require_nil(
             contribution.descriptor,
             path ++ [field_segment("descriptor")],
             :descriptor_forbidden
           ),
         :ok <-
           require_value(
             contribution.source_lane,
             :legacy_plugin,
             path ++ [field_segment("source_lane")],
             :owner_lane_mismatch
           ),
         :ok <-
           require_value(
             contribution.owner_order.namespace,
             :legacy_plugin,
             path ++ [field_segment("owner_order"), field_segment("namespace")],
             :owner_order_mismatch
           ),
         :ok <-
           require_positive_integer(
             contribution.owner_order.value,
             path ++ [field_segment("owner_order"), field_segment("value")]
           ),
         :ok <-
           require_legacy_compatibility_kind(
             contribution.compatibility.kind,
             path ++ [field_segment("compatibility"), field_segment("kind")]
           ),
         :ok <-
           validate_legacy_alias_shape(
             contribution.compatibility,
             path ++ [field_segment("compatibility")]
           ) do
      cond do
        not is_nil(owner.application) ->
          owner_mismatch(
            path ++ [field_segment("owner"), field_segment("application")],
            "nil",
            atom_string(owner.application),
            owner_reference
          )

        contribution.compatibility.legacy_id != owner.id ->
          owner_mismatch(
            path ++ [field_segment("compatibility"), field_segment("legacy_id")],
            owner.id,
            contribution.compatibility.legacy_id,
            owner_reference
          )

        true ->
          :ok
      end
    end
  end

  defp validate_declared_contribution(%Contribution{} = contribution, path) do
    owner = contribution.owner
    owner_reference = owner_ref(owner)

    with :ok <-
           require_nil(
             contribution.implementation_module,
             path ++ [field_segment("implementation_module")],
             :declared_contribution_cannot_grant_code,
             owner_reference
           ),
         :ok <-
           require_nil(
             contribution.descriptor,
             path ++ [field_segment("descriptor")],
             :descriptor_forbidden
           ),
         :ok <-
           require_value(
             contribution.source_lane,
             :declared,
             path ++ [field_segment("source_lane")],
             :owner_lane_mismatch
           ),
         :ok <-
           require_value(
             contribution.owner_order.namespace,
             :declared_pack,
             path ++ [field_segment("owner_order"), field_segment("namespace")],
             :owner_order_mismatch
           ),
         :ok <-
           require_value(
             contribution.compatibility.kind,
             :declared,
             path ++ [field_segment("compatibility"), field_segment("kind")],
             :owner_compatibility_mismatch
           ),
         :ok <-
           require_nil(
             contribution.compatibility.legacy_id,
             path ++ [field_segment("compatibility"), field_segment("legacy_id")],
             :legacy_id_forbidden
           ),
         :ok <-
           require_nil(
             contribution.compatibility.alias_of,
             path ++ [field_segment("compatibility"), field_segment("alias_of")],
             :alias_target_forbidden
           ),
         :ok <-
           validate_declared_callbacks(contribution.callbacks, path, owner_reference) do
      if contribution.owner_order.value == owner.id do
        :ok
      else
        owner_mismatch(
          path ++ [field_segment("owner_order"), field_segment("value")],
          owner.id,
          to_string(contribution.owner_order.value),
          owner_reference
        )
      end
    end
  end

  defp validate_declared_callbacks(callbacks, path, owner_reference) do
    callback =
      Enum.find(RowSchemas.callback_order(), fn callback ->
        callback != :skill_roots and Map.fetch!(callbacks, callback) != []
      end)

    if is_nil(callback) do
      :ok
    else
      invalid_value(
        path ++ [field_segment("callbacks"), field_segment(Atom.to_string(callback))],
        :declared_callback_not_data_only,
        owner_reference
      )
    end
  end

  defp validate_required_module(%Contribution{implementation_module: module}, _path)
       when is_atom(module) and module not in [nil, true, false],
       do: :ok

  defp validate_required_module(%Contribution{owner: owner}, path),
    do:
      invalid_value(
        path ++ [field_segment("implementation_module")],
        :implementation_module_required,
        owner_ref(owner)
      )

  defp validate_descriptor_record(nil, path), do: invalid_value(path, :descriptor_required)

  defp validate_descriptor_record(%Descriptor{} = descriptor, path) do
    with :ok <- validate_exact_struct_at(descriptor, Descriptor, path),
         :ok <-
           nested_schema_error(
             descriptor.schema_version,
             path ++ [field_segment("schema_version")]
           ) do
      case Descriptor.validate(descriptor) do
        {:ok, ^descriptor} ->
          :ok

        {:error, {:invalid_descriptor, field}} ->
          invalid_value(path ++ [field_segment(Atom.to_string(field))], :invalid_descriptor)
      end
    end
  end

  defp validate_descriptor_record(value, path), do: invalid_type_at(path, "Descriptor", value)

  defp require_value(actual, expected, _path, _reason) when actual == expected, do: :ok
  defp require_value(_actual, _expected, path, reason), do: invalid_value(path, reason)

  defp require_nil(value, path, reason, owner \\ nil)
  defp require_nil(nil, _path, _reason, _owner), do: :ok
  defp require_nil(_value, path, reason, owner), do: invalid_value(path, reason, owner)

  defp require_non_neg_integer(value, _path) when is_integer(value) and value >= 0, do: :ok
  defp require_non_neg_integer(_value, path), do: invalid_value(path, :non_neg_integer_required)

  defp require_positive_integer(value, _path) when is_integer(value) and value > 0, do: :ok
  defp require_positive_integer(_value, path), do: invalid_value(path, :positive_integer_required)

  defp require_legacy_compatibility_kind(kind, _path)
       when kind in [:legacy_plugin, :deprecated_alias],
       do: :ok

  defp require_legacy_compatibility_kind(_kind, path),
    do: invalid_value(path, :owner_compatibility_mismatch)

  defp validate_legacy_alias_shape(%Compatibility{kind: :legacy_plugin, alias_of: nil}, _path),
    do: :ok

  defp validate_legacy_alias_shape(%Compatibility{kind: :legacy_plugin}, path),
    do: invalid_value(path ++ [field_segment("alias_of")], :alias_target_forbidden)

  defp validate_legacy_alias_shape(
         %Compatibility{kind: :deprecated_alias, alias_of: %Target{kind: :contribution}},
         _path
       ),
       do: :ok

  defp validate_legacy_alias_shape(%Compatibility{kind: :deprecated_alias, alias_of: nil}, path),
    do: invalid_value(path ++ [field_segment("alias_of")], :alias_target_required)

  defp validate_legacy_alias_shape(%Compatibility{kind: :deprecated_alias}, path),
    do: invalid_value(path ++ [field_segment("alias_of")], :contribution_target_required)

  defp validate_contributions(contributions) do
    contributions
    |> sort_contributions()
    |> Enum.reduce_while(:ok, fn
      %Contribution{
        owner: %Owner{kind: kind} = owner,
        implementation_module: implementation_module
      },
      :ok
      when kind in [:compiled_pack, :legacy_plugin] and
             (not is_atom(implementation_module) or implementation_module in [nil, true, false]) ->
        {:halt,
         {:error,
          [
            validation_diagnostic(
              :invalid_value,
              [
                field_segment("contributions"),
                identity_segment(owner.id),
                field_segment("implementation_module")
              ],
              %{reason: :implementation_module_required},
              owner_ref(owner)
            )
          ]}}

      %Contribution{
        owner: %Owner{kind: :declared_pack} = owner,
        implementation_module: implementation_module
      },
      :ok
      when not is_nil(implementation_module) ->
        {:halt,
         {:error,
          [
            validation_diagnostic(
              :invalid_value,
              [
                field_segment("contributions"),
                identity_segment(owner.id),
                field_segment("implementation_module")
              ],
              %{reason: :declared_contribution_cannot_grant_code},
              owner_ref(owner)
            )
          ]}}

      %Contribution{
        owner: %Owner{kind: :compiled_pack, id: id} = owner,
        descriptor: %Descriptor{id: descriptor_id}
      },
      :ok
      when id != descriptor_id ->
        {:halt,
         {:error,
          [
            validation_diagnostic(
              :owner_mismatch,
              [
                field_segment("contributions"),
                identity_segment(id),
                field_segment("descriptor"),
                field_segment("id")
              ],
              %{expected: id, actual: descriptor_id},
              owner_ref(owner)
            )
          ]}}

      %Contribution{
        owner: %Owner{kind: :legacy_plugin, application: application} = owner
      },
      :ok
      when not is_nil(application) ->
        {:halt,
         {:error,
          [
            validation_diagnostic(
              :owner_mismatch,
              [
                field_segment("contributions"),
                identity_segment(owner.id),
                field_segment("owner"),
                field_segment("application")
              ],
              %{expected: "nil", actual: atom_string(application)},
              owner_ref(owner)
            )
          ]}}

      %Contribution{
        owner: %Owner{kind: :legacy_plugin, id: id} = owner,
        compatibility: %Compatibility{kind: :legacy_plugin, legacy_id: legacy_id}
      },
      :ok
      when id != legacy_id ->
        {:halt,
         {:error,
          [
            validation_diagnostic(
              :owner_mismatch,
              [
                field_segment("contributions"),
                identity_segment(id),
                field_segment("compatibility"),
                field_segment("legacy_id")
              ],
              %{expected: id, actual: legacy_id},
              owner_ref(owner)
            )
          ]}}

      _contribution, :ok ->
        {:cont, :ok}
    end)
  end

  defp validate_contribution_owner_ids(contributions) do
    contributions
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {%Contribution{owner: %Owner{id: id}}, index}, :ok ->
        if canonical_string?(id) do
          {:cont, :ok}
        else
          {:halt,
           {:error,
            [
              validation_diagnostic(
                :invalid_value,
                [
                  field_segment("contributions"),
                  index_segment(index),
                  field_segment("owner"),
                  field_segment("id")
                ],
                %{reason: :canonical_string_required}
              )
            ]}}
        end

      {_contribution, _index}, :ok ->
        {:cont, :ok}
    end)
  end

  defp owner_ref(%Owner{} = owner) do
    %OwnerRef{schema_version: 1, kind: owner.kind, id: owner.id}
  end

  defp validate_diagnostics(diagnostics) do
    diagnostics
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {diagnostic, index}, :ok ->
      case validate_diagnostic_record(diagnostic, index) do
        :ok -> {:cont, :ok}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
  end

  defp validate_cross_record_semantics(contributions, actions, diagnostics) do
    with :ok <- validate_declared_applications(contributions),
         :ok <- validate_disabled_contribution_inertness(contributions, actions),
         :ok <- validate_disabled_diagnostic_bindings(contributions, diagnostics),
         :ok <- validate_disabled_diagnostic_counts(contributions, diagnostics),
         :ok <- validate_child_spec_diagnostic_bindings(contributions, diagnostics) do
      :ok
    end
  end

  defp validate_declared_applications(contributions) do
    compiled_applications =
      contributions
      |> Enum.reduce(MapSet.new(), fn
        %Contribution{
          owner: %Owner{kind: :compiled_pack, application: application}
        },
        applications
        when not is_nil(application) ->
          MapSet.put(applications, application)

        _contribution, applications ->
          applications
      end)

    contributions
    |> sort_contributions()
    |> Enum.reduce_while(:ok, fn
      %Contribution{
        owner: %Owner{kind: :declared_pack, application: application} = owner
      },
      :ok
      when not is_nil(application) ->
        if MapSet.member?(compiled_applications, application) do
          {:cont, :ok}
        else
          {:halt,
           invalid_value(
             contribution_path(owner) ++
               [field_segment("owner"), field_segment("application")],
             :unreconciled_declared_application,
             owner_ref(owner)
           )}
        end

      _contribution, :ok ->
        {:cont, :ok}
    end)
  end

  defp validate_disabled_contribution_inertness(contributions, actions) do
    contributions
    |> sort_contributions()
    |> Enum.reduce_while(:ok, &validate_disabled_contribution(&1, &2, actions))
  end

  defp validate_disabled_contribution(
         %Contribution{
           owner: %Owner{kind: owner_kind, id: owner_id} = owner,
           compatibility: %Compatibility{enabled: false},
           callbacks: callbacks
         },
         :ok,
         actions
       )
       when owner_kind in [:legacy_plugin, :declared_pack] do
    case first_nonempty_callback(callbacks) do
      nil -> validate_disabled_owner_action(actions, owner, owner_id)
      callback -> disabled_callback_error(owner, callback)
    end
  end

  defp validate_disabled_contribution(_contribution, :ok, _actions), do: {:cont, :ok}

  defp validate_disabled_owner_action(actions, owner, owner_id) do
    case disabled_owner_action(actions, owner_id) do
      nil ->
        {:cont, :ok}

      %ActionBinding{name: name} ->
        {:halt,
         invalid_value(
           [field_segment("action_bindings"), identity_segment(name)],
           :disabled_contribution_effective_binding,
           owner_ref(owner)
         )}
    end
  end

  defp disabled_callback_error(owner, callback) do
    {:halt,
     invalid_value(
       contribution_path(owner) ++
         [field_segment("callbacks"), field_segment(Atom.to_string(callback))],
       :disabled_contribution_must_be_inert,
       owner_ref(owner)
     )}
  end

  defp first_nonempty_callback(callbacks) do
    Enum.find(RowSchemas.callback_order(), fn callback ->
      Map.fetch!(callbacks, callback) != []
    end)
  end

  defp disabled_owner_action(actions, owner_id) do
    actions
    |> sort_actions()
    |> Enum.find(fn
      %ActionBinding{
        source_lane: :legacy_plugin,
        normalized_capability: %{plugin_id: ^owner_id}
      } ->
        true

      _action ->
        false
    end)
  end

  defp validate_disabled_diagnostic_bindings(contributions, diagnostics) do
    diagnostics
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {%CompatibilityDiagnostic{code: :disabled_plugin} = diagnostic, index}, :ok ->
        path = [field_segment("compatibility_diagnostics"), index_segment(index)]

        case validate_disabled_diagnostic_binding(diagnostic, contributions, path) do
          :ok -> {:cont, :ok}
          {:error, _diagnostics} = error -> {:halt, error}
        end

      {_diagnostic, _index}, :ok ->
        {:cont, :ok}
    end)
  end

  defp validate_disabled_diagnostic_binding(
         %CompatibilityDiagnostic{
           severity: severity,
           path: diagnostic_path,
           owner: %OwnerRef{kind: owner_kind, id: owner_id}
         } = diagnostic,
         contributions,
         path
       )
       when owner_kind in [:legacy_plugin, :declared_pack] do
    expected_path = disabled_plugin_path(owner_id)

    cond do
      not disabled_owner?(contributions, owner_kind, owner_id) ->
        invalid_value(
          path ++ [field_segment("owner")],
          :disabled_plugin_owner_not_disabled,
          diagnostic.owner
        )

      severity != :warning ->
        invalid_value(
          path ++ [field_segment("severity")],
          :disabled_plugin_warning_required,
          diagnostic.owner
        )

      diagnostic_path != expected_path ->
        invalid_value(
          path ++ [field_segment("path")],
          :disabled_plugin_path_mismatch,
          diagnostic.owner
        )

      true ->
        :ok
    end
  end

  defp validate_disabled_diagnostic_binding(
         %CompatibilityDiagnostic{} = diagnostic,
         _contributions,
         path
       ) do
    invalid_value(
      path ++ [field_segment("owner")],
      :disabled_plugin_owner_not_disabled,
      valid_diagnostic_owner(diagnostic.owner)
    )
  end

  defp validate_disabled_diagnostic_counts(contributions, diagnostics) do
    contributions
    |> sort_contributions()
    |> Enum.reduce_while(:ok, fn
      %Contribution{
        owner: %Owner{kind: owner_kind, id: owner_id} = owner,
        compatibility: %Compatibility{enabled: false}
      },
      :ok
      when owner_kind in [:legacy_plugin, :declared_pack] ->
        count =
          Enum.count(diagnostics, fn
            %CompatibilityDiagnostic{
              code: :disabled_plugin,
              owner: %OwnerRef{kind: ^owner_kind, id: ^owner_id}
            } ->
              true

            _diagnostic ->
              false
          end)

        reason =
          case count do
            0 -> :missing_disabled_plugin_diagnostic
            1 -> nil
            _count -> :multiple_disabled_plugin_diagnostics
          end

        if is_nil(reason) do
          {:cont, :ok}
        else
          {:halt,
           invalid_value(
             contribution_path(owner) ++
               [field_segment("compatibility"), field_segment("enabled")],
             reason,
             owner_ref(owner)
           )}
        end

      _contribution, :ok ->
        {:cont, :ok}
    end)
  end

  defp disabled_owner?(contributions, owner_kind, owner_id) do
    Enum.any?(contributions, fn
      %Contribution{
        owner: %Owner{kind: ^owner_kind, id: ^owner_id},
        compatibility: %Compatibility{enabled: false}
      } ->
        true

      _contribution ->
        false
    end)
  end

  defp disabled_plugin_path(owner_id) do
    [
      field_segment("plugins"),
      identity_segment(owner_id),
      field_segment("status")
    ]
  end

  defp validate_child_spec_diagnostic_bindings(contributions, diagnostics) do
    diagnostics
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, MapSet.new()},
      &validate_child_spec_diagnostic_entry(&1, &2, contributions)
    )
    |> case do
      {:ok, %MapSet{}} -> :ok
      {:error, _diagnostics} = error -> error
    end
  end

  defp validate_child_spec_diagnostic_entry(
         {%CompatibilityDiagnostic{
            code: :child_spec,
            owner: %OwnerRef{kind: :legacy_plugin, id: owner_id}
          } = diagnostic, index},
         {:ok, seen},
         contributions
       ) do
    path = [field_segment("compatibility_diagnostics"), index_segment(index)]

    with :ok <- validate_child_spec_diagnostic_binding(diagnostic, contributions, path) do
      continue_child_spec_diagnostic(diagnostic, path, owner_id, seen)
    else
      {:error, _diagnostics} = error -> {:halt, error}
    end
  end

  defp validate_child_spec_diagnostic_entry(
         {%CompatibilityDiagnostic{code: :child_spec} = diagnostic, index},
         {:ok, _seen},
         _contributions
       ) do
    path = [field_segment("compatibility_diagnostics"), index_segment(index)]

    {:halt,
     invalid_value(
       path ++ [field_segment("owner")],
       :child_spec_owner_not_enabled_legacy,
       valid_diagnostic_owner(diagnostic.owner)
     )}
  end

  defp validate_child_spec_diagnostic_entry(
         {_diagnostic, _index},
         {:ok, seen},
         _contributions
       ),
       do: {:cont, {:ok, seen}}

  defp continue_child_spec_diagnostic(diagnostic, path, owner_id, seen) do
    if MapSet.member?(seen, owner_id) do
      {:halt, invalid_value(path, :duplicate_child_spec_diagnostic, diagnostic.owner)}
    else
      {:cont, {:ok, MapSet.put(seen, owner_id)}}
    end
  end

  defp validate_child_spec_diagnostic_binding(
         %CompatibilityDiagnostic{
           severity: severity,
           path: diagnostic_path,
           owner: %OwnerRef{kind: :legacy_plugin, id: owner_id} = owner
         },
         contributions,
         path
       ) do
    cond do
      severity != :warning ->
        invalid_value(
          path ++ [field_segment("severity")],
          :child_spec_warning_required,
          owner
        )

      diagnostic_path != child_spec_plugin_path(owner_id) ->
        invalid_value(
          path ++ [field_segment("path")],
          :child_spec_path_mismatch,
          owner
        )

      not enabled_legacy_plugin_owner?(contributions, owner_id) ->
        invalid_value(
          path ++ [field_segment("owner")],
          :child_spec_owner_not_enabled_legacy,
          owner
        )

      true ->
        :ok
    end
  end

  defp child_spec_plugin_path(owner_id) do
    [
      field_segment("plugins"),
      identity_segment(owner_id),
      field_segment("children")
    ]
  end

  defp enabled_legacy_plugin_owner?(contributions, owner_id) do
    Enum.any?(contributions, fn
      %Contribution{
        owner: %Owner{kind: :legacy_plugin, id: ^owner_id},
        compatibility: %Compatibility{kind: kind, enabled: true}
      } ->
        kind in [:legacy_plugin, :deprecated_alias]

      _contribution ->
        false
    end)
  end

  defp contribution_path(%Owner{id: owner_id}),
    do: [field_segment("contributions"), identity_segment(owner_id)]

  defp validate_diagnostic_record(%CompatibilityDiagnostic{} = diagnostic, index) do
    path = [field_segment("compatibility_diagnostics"), index_segment(index)]

    with :ok <- validate_exact_struct_at(diagnostic, CompatibilityDiagnostic, path),
         :ok <-
           nested_schema_error(
             diagnostic.schema_version,
             path ++ [field_segment("schema_version")]
           ),
         :ok <- validate_diagnostic_classification(diagnostic, path),
         :ok <- validate_diagnostic_payload(diagnostic, path) do
      :ok
    end
  end

  defp validate_diagnostic_classification(diagnostic, path) do
    cond do
      diagnostic.code not in @compatibility_diagnostic_codes ->
        invalid_value(
          path ++ [field_segment("code")],
          :unsupported_code,
          valid_diagnostic_owner(diagnostic.owner)
        )

      diagnostic.severity not in [:error, :warning] ->
        invalid_value(
          path ++ [field_segment("severity")],
          :unsupported_severity,
          valid_diagnostic_owner(diagnostic.owner)
        )

      true ->
        :ok
    end
  end

  defp validate_diagnostic_payload(diagnostic, path) do
    with :ok <- validate_diagnostic_path(diagnostic.path, path ++ [field_segment("path")]),
         :ok <- validate_owner_ref_record(diagnostic.owner, path ++ [field_segment("owner")]),
         :ok <-
           validate_diagnostic_detail_record(
             diagnostic.code,
             diagnostic.detail,
             path ++ [field_segment("detail")],
             diagnostic.owner
           ) do
      :ok
    end
  end

  defp validate_diagnostic_path(path_segments, path) when is_list(path_segments) do
    path_segments
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {segment, index}, :ok ->
      case validate_path_segment(segment, path ++ [index_segment(index)]) do
        :ok -> {:cont, :ok}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
  end

  defp validate_diagnostic_path(value, path), do: invalid_type_at(path, "list", value)

  defp validate_path_segment(%PathSegment{} = segment, path) do
    with :ok <- validate_exact_struct_at(segment, PathSegment, path),
         :ok <-
           nested_schema_error(segment.schema_version, path ++ [field_segment("schema_version")]) do
      cond do
        segment.kind not in [:field, :index, :identity] ->
          invalid_value(path ++ [field_segment("kind")], :unsupported_path_segment_kind)

        segment.kind == :index and
            (not is_integer(segment.value) or segment.value < 0) ->
          invalid_value(path ++ [field_segment("value")], :non_neg_integer_required)

        segment.kind in [:field, :identity] and not plain_string?(segment.value) ->
          invalid_type_at(path ++ [field_segment("value")], "string", segment.value)

        true ->
          :ok
      end
    end
  end

  defp validate_path_segment(value, path), do: invalid_type_at(path, "PathSegment", value)

  defp validate_owner_ref_record(nil, _path), do: :ok

  defp validate_owner_ref_record(%OwnerRef{} = owner, path) do
    with :ok <- validate_exact_struct_at(owner, OwnerRef, path),
         :ok <-
           nested_schema_error(owner.schema_version, path ++ [field_segment("schema_version")]) do
      cond do
        owner.kind not in [:compiled_pack, :legacy_plugin, :declared_pack] ->
          invalid_value(path ++ [field_segment("kind")], :unsupported_owner_kind)

        not canonical_string?(owner.id) ->
          invalid_value(path ++ [field_segment("id")], :canonical_string_required)

        true ->
          :ok
      end
    end
  end

  defp validate_owner_ref_record(value, path), do: invalid_type_at(path, "OwnerRef_or_nil", value)

  defp valid_diagnostic_owner(
         %OwnerRef{
           schema_version: 1,
           kind: kind,
           id: id
         } = owner
       )
       when kind in [:compiled_pack, :legacy_plugin, :declared_pack] and is_binary(id),
       do: owner

  defp valid_diagnostic_owner(_owner), do: nil

  defp validate_diagnostic_detail_record(:legacy_registry, detail, path, owner) do
    with :ok <- validate_exact_detail_keys(detail, [:source_lane, :legacy_index], path, owner) do
      cond do
        not is_atom(detail.source_lane) or detail.source_lane in [nil, true, false] ->
          invalid_type_at(
            path ++ [field_segment("source_lane")],
            "atom",
            detail.source_lane,
            owner
          )

        not is_integer(detail.legacy_index) or detail.legacy_index <= 0 ->
          invalid_value(
            path ++ [field_segment("legacy_index")],
            :positive_integer_required,
            owner
          )

        true ->
          :ok
      end
    end
  end

  defp validate_diagnostic_detail_record(:disabled_plugin, detail, path, owner) do
    with :ok <- validate_exact_detail_keys(detail, [:source, :status], path, owner) do
      cond do
        not is_atom(detail.source) or detail.source in [nil, true, false] ->
          invalid_type_at(path ++ [field_segment("source")], "atom", detail.source, owner)

        detail.status != :disabled ->
          invalid_value(path ++ [field_segment("status")], :disabled_status_required, owner)

        true ->
          :ok
      end
    end
  end

  defp validate_diagnostic_detail_record(:deprecated_alias, detail, path, owner) do
    with :ok <- validate_exact_detail_keys(detail, [:alias_kind, :target], path, owner),
         true <- is_atom(detail.alias_kind) and detail.alias_kind not in [nil, true, false],
         :ok <- validate_target(detail.target, path ++ [field_segment("target")]) do
      :ok
    else
      false ->
        invalid_type_at(path ++ [field_segment("alias_kind")], "atom", detail.alias_kind, owner)

      {:error, _diagnostics} = error ->
        error
    end
  end

  defp validate_diagnostic_detail_record(:child_spec, detail, path, owner) do
    with :ok <- validate_exact_detail_keys(detail, [:child_spec], path, owner),
         :ok <-
           validate_child_spec(detail.child_spec, path ++ [field_segment("child_spec")], owner) do
      :ok
    end
  end

  defp validate_diagnostic_detail_record(:collision, detail, path, owner) do
    with :ok <- validate_exact_detail_keys(detail, [:identity, :participants], path, owner),
         true <- canonical_string?(detail.identity),
         :ok <-
           validate_collision_participants(
             detail.participants,
             path ++ [field_segment("participants")],
             owner
           ) do
      :ok
    else
      false ->
        invalid_value(path ++ [field_segment("identity")], :canonical_string_required, owner)

      {:error, _diagnostics} = error ->
        error
    end
  end

  defp validate_exact_detail_keys(detail, expected, path, owner) when is_map(detail) do
    actual = Map.keys(detail)

    cond do
      missing = Enum.find(expected, &(&1 not in actual)) ->
        name = Atom.to_string(missing)
        missing_field(path ++ [field_segment(name)], name, owner)

      unknown =
          actual
          |> Enum.reject(&(&1 in expected))
          |> Enum.sort_by(&field_name/1)
          |> List.first() ->
        name = field_name(unknown)
        unknown_field(path ++ [field_segment(name)], name, owner)

      true ->
        :ok
    end
  end

  defp validate_exact_detail_keys(value, _expected, path, owner),
    do: invalid_type_at(path, "map", value, owner)

  defp validate_child_spec(%ChildSpecProjection{} = child_spec, path, owner) do
    with :ok <- validate_exact_struct_at(child_spec, ChildSpecProjection, path),
         :ok <-
           nested_schema_error(
             child_spec.schema_version,
             path ++ [field_segment("schema_version")]
           ) do
      start_fields = [
        child_spec.start_module,
        child_spec.start_function,
        child_spec.start_arity,
        child_spec.start_args_sha256
      ]

      cond do
        not canonical_child_id?(child_spec.id) ->
          invalid_value(path ++ [field_segment("id")], :canonical_child_id_required, owner)

        Enum.any?(start_fields, &is_nil/1) and not Enum.all?(start_fields, &is_nil/1) ->
          invalid_value(path, :complete_start_mfa_required, owner)

        not valid_start_fields?(start_fields) ->
          invalid_value(path, :invalid_start_mfa, owner)

        child_spec.restart not in [nil, "permanent", "transient", "temporary"] ->
          invalid_value(path ++ [field_segment("restart")], :unsupported_restart, owner)

        not valid_shutdown?(child_spec.shutdown) ->
          invalid_value(path ++ [field_segment("shutdown")], :unsupported_shutdown, owner)

        child_spec.type not in [nil, "worker", "supervisor"] ->
          invalid_value(path ++ [field_segment("type")], :unsupported_child_type, owner)

        true ->
          :ok
      end
    end
  end

  defp validate_child_spec(value, path, owner),
    do: invalid_type_at(path, "ChildSpecProjection", value, owner)

  defp valid_start_fields?([nil, nil, nil, nil]), do: true

  defp valid_start_fields?([module, function, arity, digest]) do
    module_string?(module) and canonical_string?(function) and is_integer(arity) and arity >= 0 and
      lowercase_sha256?(digest)
  end

  defp canonical_child_id?(nil), do: true
  defp canonical_child_id?(value) when is_integer(value), do: true
  defp canonical_child_id?(value) when is_binary(value), do: plain_string?(value)

  defp canonical_child_id?(%{"tuple" => [nested]} = value) when map_size(value) == 1,
    do: canonical_child_id?(nested)

  defp canonical_child_id?(_value), do: false

  defp valid_shutdown?(value) when is_integer(value) and value >= 0, do: true
  defp valid_shutdown?(value) when value in [nil, "brutal_kill", "infinity"], do: true
  defp valid_shutdown?(_value), do: false

  defp validate_collision_participants(participants, path, owner) when is_list(participants) do
    participants
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, MapSet.new()},
      &validate_collision_participant(&1, &2, path, owner)
    )
    |> case do
      {:ok, %MapSet{}} -> :ok
      {:error, _diagnostics} = error -> error
    end
  end

  defp validate_collision_participants(value, path, owner),
    do: invalid_type_at(path, "list", value, owner)

  defp validate_collision_participant({target, index}, {:ok, seen}, path, owner) do
    with :ok <- validate_target(target, path ++ [index_segment(index)]) do
      continue_collision_participant(target, seen, path, owner)
    else
      {:error, _diagnostics} = error -> {:halt, error}
    end
  end

  defp continue_collision_participant(target, seen, path, owner) do
    key = {target.kind, target.owner_id, target.identity}

    if MapSet.member?(seen, key) do
      identity = Enum.join([target.kind, target.owner_id, target.identity], ":")

      {:halt,
       {:error, [validation_diagnostic(:duplicate_identity, path, %{identity: identity}, owner)]}}
    else
      {:cont, {:ok, MapSet.put(seen, key)}}
    end
  end

  defp validate_aliases(contributions, actions, aliases) do
    with :ok <- validate_alias_records(aliases),
         :ok <- validate_unique_aliases(aliases, contributions),
         :ok <- validate_deprecated_contribution_aliases(contributions, aliases),
         :ok <- validate_action_alias_sources(contributions, aliases),
         :ok <- validate_alias_targets(aliases, contributions, actions) do
      :ok
    end
  end

  defp validate_alias_targets(aliases, contributions, actions) do
    aliases
    |> sort_aliases()
    |> Enum.reduce_while(:ok, fn compatibility_alias, :ok ->
      case validate_alias(compatibility_alias, contributions, actions) do
        :ok -> {:cont, :ok}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
  end

  defp validate_alias_records(aliases) do
    aliases
    |> sort_aliases()
    |> Enum.reduce_while(:ok, fn compatibility_alias, :ok ->
      case validate_alias_record(compatibility_alias) do
        :ok -> {:cont, :ok}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
  end

  defp validate_alias_record(%CompatibilityAlias{} = compatibility_alias) do
    owner_id = compatibility_alias.owner_id

    base_path = [
      field_segment("compatibility_aliases"),
      identity_segment(safe_identity(owner_id))
    ]

    cond do
      exact_struct(compatibility_alias, CompatibilityAlias) != :ok ->
        canonicalization_error_at(base_path, "compatibility_alias")

      compatibility_alias.schema_version != 1 ->
        nested_schema_error(
          compatibility_alias.schema_version,
          base_path ++ [field_segment("schema_version")]
        )

      compatibility_alias.kind not in [:legacy_plugin, :deprecated_alias] ->
        invalid_value(base_path ++ [field_segment("kind")], :unsupported_alias_kind)

      not canonical_string?(owner_id) ->
        invalid_value(base_path ++ [field_segment("owner_id")], :canonical_string_required)

      true ->
        with :ok <-
               validate_target(compatibility_alias.target, base_path ++ [field_segment("target")]),
             :ok <- validate_alias_kind_target(compatibility_alias, base_path),
             :ok <- validate_alias_module(compatibility_alias, base_path),
             :ok <-
               validate_lowercase_sha256(
                 compatibility_alias.authority_sha256,
                 base_path ++ [field_segment("authority_sha256")]
               ) do
          :ok
        end
    end
  end

  defp validate_alias_kind_target(
         %CompatibilityAlias{kind: :legacy_plugin, target: %Target{kind: :action}},
         _base_path
       ),
       do: :ok

  defp validate_alias_kind_target(
         %CompatibilityAlias{kind: :deprecated_alias, target: %Target{kind: :contribution}},
         _base_path
       ),
       do: :ok

  defp validate_alias_kind_target(_compatibility_alias, base_path),
    do: invalid_value(base_path ++ [field_segment("kind")], :alias_kind_target_mismatch)

  defp validate_alias_module(%CompatibilityAlias{module: module}, _base_path)
       when is_atom(module) and module not in [nil, true, false],
       do: :ok

  defp validate_alias_module(%CompatibilityAlias{module: nil}, _base_path), do: :ok

  defp validate_alias_module(_compatibility_alias, base_path),
    do: invalid_value(base_path ++ [field_segment("module")], :module_or_nil_required)

  defp validate_action_alias_sources(contributions, aliases) do
    contributions
    |> sort_contributions()
    |> Enum.reduce_while(:ok, &validate_action_alias_contribution(&1, &2, aliases))
  end

  defp validate_action_alias_contribution(contribution, :ok, aliases) do
    contribution
    |> alias_source_action_rows()
    |> Enum.sort_by(&row_sort_key/1)
    |> Enum.reduce_while(:ok, &validate_action_alias_row(&1, &2, contribution, aliases))
    |> continue_or_halt()
  end

  defp validate_action_alias_row(row, :ok, contribution, aliases) do
    row_owner_id = row.owner_id
    row_identity = row.identity[:value]

    matching =
      Enum.count(aliases, fn
        %CompatibilityAlias{
          kind: :legacy_plugin,
          owner_id: ^row_owner_id,
          target: %Target{kind: :action, identity: ^row_identity}
        } ->
          true

        _compatibility_alias ->
          false
      end)

    validate_action_alias_count(matching, contribution, row)
  end

  defp validate_action_alias_count(1, _contribution, _row), do: {:cont, :ok}

  defp validate_action_alias_count(0, contribution, row) do
    {:halt,
     invalid_value(
       row_path(contribution, row),
       :missing_compatibility_alias,
       owner_ref(contribution.owner)
     )}
  end

  defp validate_action_alias_count(_count, contribution, row) do
    {:halt,
     invalid_value(
       row_path(contribution, row),
       :multiple_compatibility_aliases,
       owner_ref(contribution.owner)
     )}
  end

  defp continue_or_halt(:ok), do: {:cont, :ok}
  defp continue_or_halt({:error, _diagnostics} = error), do: {:halt, error}

  defp alias_source_action_rows(%Contribution{callbacks: callbacks}) when is_map(callbacks) do
    callbacks
    |> Map.get(:actions, [])
    |> Enum.filter(fn
      %Row{order: %{namespace: :alias_target}} -> true
      _row -> false
    end)
  end

  defp alias_source_action_rows(_contribution), do: []

  defp validate_deprecated_contribution_aliases(contributions, aliases) do
    contributions
    |> sort_contributions()
    |> Enum.reduce_while(:ok, fn
      %Contribution{
        owner: %Owner{id: owner_id} = contribution_owner,
        compatibility: %Compatibility{kind: :deprecated_alias, alias_of: %Target{} = target}
      },
      :ok ->
        matching_aliases =
          Enum.count(aliases, fn
            %CompatibilityAlias{
              kind: :deprecated_alias,
              owner_id: ^owner_id,
              target: ^target
            } ->
              true

            _compatibility_alias ->
              false
          end)

        if matching_aliases == 1 do
          {:cont, :ok}
        else
          {:halt,
           {:error,
            [
              validation_diagnostic(
                :alias_mismatch,
                [
                  field_segment("contributions"),
                  identity_segment(owner_id),
                  field_segment("compatibility"),
                  field_segment("alias_of")
                ],
                %{owner_id: owner_id, target: target},
                owner_ref(contribution_owner)
              )
            ]}}
        end

      _contribution, :ok ->
        {:cont, :ok}
    end)
  end

  defp validate_unique_aliases(aliases, contributions) do
    aliases
    |> sort_aliases()
    |> Enum.reduce_while(MapSet.new(), &validate_unique_alias(&1, &2, contributions))
    |> case do
      %MapSet{} -> :ok
      {:error, _diagnostics} = error -> error
    end
  end

  defp validate_unique_alias(
         %CompatibilityAlias{target: %Target{} = target} = compatibility_alias,
         seen,
         contributions
       ) do
    key = alias_identity_key(compatibility_alias, target)

    if MapSet.member?(seen, key) do
      {:halt, duplicate_alias_identity(compatibility_alias, target, contributions)}
    else
      {:cont, MapSet.put(seen, key)}
    end
  end

  defp validate_unique_alias(_compatibility_alias, seen, _contributions), do: {:cont, seen}

  defp alias_identity_key(compatibility_alias, target) do
    {
      compatibility_alias.kind,
      compatibility_alias.owner_id,
      target.kind,
      target.owner_id,
      target.identity
    }
  end

  defp duplicate_alias_identity(compatibility_alias, target, contributions) do
    identity =
      Enum.join(
        [
          compatibility_alias.kind,
          compatibility_alias.owner_id,
          target.kind,
          target.owner_id,
          target.identity
        ],
        ":"
      )

    owner = alias_contribution_owner(contributions, compatibility_alias.owner_id)

    {:error,
     [
       validation_diagnostic(
         :duplicate_identity,
         [
           field_segment("compatibility_aliases"),
           identity_segment(compatibility_alias.owner_id)
         ],
         %{identity: identity},
         owner
       )
     ]}
  end

  defp alias_contribution_owner(contributions, owner_id) do
    case contribution_by_id(contributions, owner_id) do
      %Contribution{owner: %Owner{} = contribution_owner} -> owner_ref(contribution_owner)
      _contribution -> nil
    end
  end

  defp validate_alias(
         %CompatibilityAlias{target: %Target{kind: :action}} = compatibility_alias,
         contributions,
         actions
       ) do
    validate_action_alias(compatibility_alias, contributions, actions)
  end

  defp validate_alias(
         %CompatibilityAlias{target: %Target{kind: :contribution}} = compatibility_alias,
         contributions,
         _actions
       ) do
    validate_contribution_alias(compatibility_alias, contributions)
  end

  defp validate_alias(_compatibility_alias, _contributions, _actions), do: :ok

  defp validate_contribution_alias(
         %CompatibilityAlias{owner_id: owner_id, target: target} = compatibility_alias,
         contributions
       ) do
    source = contribution_by_id(contributions, owner_id)
    target_contribution = contribution_by_id(contributions, target.owner_id)

    with %Contribution{} <- source,
         %Contribution{} <- target_contribution,
         true <- target.identity == target_contribution.owner.id,
         true <- compatibility_alias.kind == :deprecated_alias,
         true <- source.compatibility.kind == :deprecated_alias,
         true <- source.compatibility.alias_of == target,
         true <- compatibility_alias.module == source.implementation_module,
         {:ok, authority} <- contribution_alias_authority(source, target_contribution) do
      expected = authority.authority_sha256

      if compatibility_alias.authority_sha256 == expected do
        :ok
      else
        {:error,
         [
           validation_diagnostic(
             :digest_mismatch,
             [
               field_segment("compatibility_aliases"),
               identity_segment(owner_id),
               field_segment("authority_sha256")
             ],
             %{expected: expected, actual: compatibility_alias.authority_sha256},
             owner_ref(source.owner)
           )
         ]}
      end
    else
      {:error, _diagnostics} -> alias_mismatch(compatibility_alias, source)
      _mismatch -> alias_mismatch(compatibility_alias, source)
    end
  end

  defp contribution_alias_rows(%Contribution{} = contribution) do
    try do
      rows =
        Enum.flat_map(RowSchemas.callback_order(), fn callback ->
          contribution.callbacks
          |> Map.fetch!(callback)
          |> Enum.reject(&alias_target_row?/1)
          |> Enum.map(&RowSchemas.alias_authority_projection!(&1, contribution))
          |> Enum.sort_by(&alias_authority_row_sort_key/1)
        end)

      {:ok, rows}
    rescue
      _error in [ArgumentError, KeyError] -> canonicalization_error("contribution_alias_rows")
    end
  end

  defp authority_subset?(source_rows, target_rows) do
    target_frequencies = Enum.frequencies(target_rows)

    source_rows
    |> Enum.frequencies()
    |> Enum.all?(fn {row, count} -> Map.get(target_frequencies, row, 0) == count end)
  end

  defp alias_target_row?(%Row{order: %{namespace: :alias_target}}), do: true
  defp alias_target_row?(_row), do: false

  defp alias_authority_row_sort_key(projection) do
    {
      projection["order_value"],
      projection["identity"]["namespace"],
      projection["identity"]["value"],
      canonical_sort_bytes(projection["authority"])
    }
  end

  defp validate_action_alias(
         %CompatibilityAlias{owner_id: owner_id, target: target} = compatibility_alias,
         contributions,
         actions
       ) do
    source_contribution = contribution_by_id(contributions, owner_id)
    target_contribution = contribution_by_id(contributions, target.owner_id)

    source_rows = alias_action_rows(source_contribution, target.identity)
    target_rows = effective_action_rows(target_contribution, target.identity)

    with %Contribution{} <- source_contribution,
         %Contribution{} <- target_contribution,
         :ok <-
           validate_action_alias_source_owner(source_contribution, compatibility_alias),
         [source_row] <- source_rows,
         [target_row] <- target_rows,
         [target_action] <-
           Enum.filter(actions, &action_row_matches?(target_contribution, target_row, &1)),
         :ok <-
           validate_action_alias_authority(
             source_row,
             target_row,
             target_action,
             compatibility_alias
           ),
         {:ok, authority_bytes} <- encode_json(source_row.source_authority) do
      expected = sha256("allbert.pack.alias.authority.v1\0" <> authority_bytes)

      if compatibility_alias.authority_sha256 == expected do
        :ok
      else
        {:error,
         [
           validation_diagnostic(
             :digest_mismatch,
             [
               field_segment("compatibility_aliases"),
               identity_segment(owner_id),
               field_segment("authority_sha256")
             ],
             %{expected: expected, actual: compatibility_alias.authority_sha256},
             owner_ref(source_contribution.owner)
           )
         ]}
      end
    else
      {:error, _diagnostics} = error ->
        error

      _mismatch ->
        alias_mismatch(compatibility_alias, source_contribution)
    end
  end

  defp validate_action_alias_source_owner(
         %Contribution{
           owner: %Owner{kind: :legacy_plugin, id: owner_id},
           source_lane: :legacy_plugin,
           compatibility: %Compatibility{kind: kind, enabled: true}
         },
         %CompatibilityAlias{owner_id: owner_id}
       )
       when kind in [:legacy_plugin, :deprecated_alias],
       do: :ok

  defp validate_action_alias_source_owner(source_contribution, compatibility_alias),
    do: alias_mismatch(compatibility_alias, source_contribution)

  defp validate_action_alias_authority(
         source_row,
         target_row,
         target_action,
         compatibility_alias
       ) do
    with {:ok, action_projection} <- action_authority_projection(target_action),
         true <- source_row.source_authority == target_row.source_authority,
         true <- source_row.source_authority == action_projection,
         true <- source_row.payload == target_row.payload,
         true <- source_row.order[:value] == target_row.order[:value],
         true <- source_row.m0_payload_sha256 == nil,
         true <- compatibility_alias.module == target_action.module do
      :ok
    else
      _mismatch -> {:error, alias_mismatch_diagnostics(compatibility_alias, nil)}
    end
  end

  defp action_authority_projection(%ActionBinding{} = action) do
    with {:ok, capability} <- project_capability(action.normalized_capability) do
      {:ok,
       %{
         "kind" => "action",
         "module" => module_string(action.module),
         "name" => action.name,
         "normalized_capability" => capability,
         "input_schema_sha256" => action.input_schema_sha256,
         "output_schema_sha256" => action.output_schema_sha256
       }}
    end
  end

  defp contribution_by_id(contributions, id) do
    Enum.find(contributions, fn
      %Contribution{owner: %Owner{id: ^id}} -> true
      _contribution -> false
    end)
  end

  defp alias_action_rows(%Contribution{callbacks: callbacks}, identity) do
    callbacks
    |> Map.get(:actions, [])
    |> Enum.filter(fn
      %Row{identity: %{value: ^identity}, order: %{namespace: :alias_target}} -> true
      _row -> false
    end)
  end

  defp alias_action_rows(_contribution, _identity), do: []

  defp effective_action_rows(%Contribution{callbacks: callbacks}, identity) do
    callbacks
    |> Map.get(:actions, [])
    |> Enum.filter(fn
      %Row{identity: %{value: ^identity}, order: %{namespace: namespace}}
      when namespace in [:legacy_index, :registry_order] ->
        true

      _row ->
        false
    end)
  end

  defp effective_action_rows(_contribution, _identity), do: []

  defp alias_mismatch(compatibility_alias, source_contribution) do
    owner =
      case source_contribution do
        %Contribution{owner: %Owner{} = contribution_owner} -> owner_ref(contribution_owner)
        _contribution -> nil
      end

    {:error, alias_mismatch_diagnostics(compatibility_alias, owner)}
  end

  defp alias_mismatch_diagnostics(compatibility_alias, owner) do
    [
      validation_diagnostic(
        :alias_mismatch,
        [
          field_segment("compatibility_aliases"),
          identity_segment(compatibility_alias.owner_id)
        ],
        %{owner_id: compatibility_alias.owner_id, target: compatibility_alias.target},
        owner
      )
    ]
  end

  defp validate_actions(actions) do
    with :ok <- validate_action_records(actions),
         :ok <- validate_unique_action_identities(actions),
         :ok <- validate_unique_action_orders(actions),
         :ok <- validate_effective_actions(actions) do
      :ok
    end
  end

  defp validate_effective_actions(actions) do
    actions
    |> sort_actions()
    |> Enum.reduce_while(:ok, fn action, :ok ->
      case validate_action(action) do
        :ok -> {:cont, :ok}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
  end

  defp validate_action_records(actions) do
    actions
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {action, index}, :ok ->
      case validate_action_record(action, index) do
        :ok -> {:cont, :ok}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
  end

  defp validate_action_record(%ActionBinding{} = action, index) do
    index_path = [field_segment("action_bindings"), index_segment(index)]

    with :ok <- validate_exact_struct_at(action, ActionBinding, index_path) do
      path = [field_segment("action_bindings"), identity_segment(safe_identity(action.name))]

      with :ok <-
             nested_schema_error(action.schema_version, path ++ [field_segment("schema_version")]),
           :ok <- validate_action_record_identity_fields(action, path),
           :ok <- validate_action_record_order_fields(action, path) do
        :ok
      end
    end
  end

  defp validate_action_record_identity_fields(action, path) do
    cond do
      not is_atom(action.module) or action.module in [nil, true, false] ->
        invalid_value(path ++ [field_segment("module")], :module_required)

      not canonical_string?(action.name) ->
        invalid_value(path ++ [field_segment("name")], :canonical_string_required)

      action.source_lane not in [:native_static, :legacy_plugin] ->
        invalid_value(path ++ [field_segment("source_lane")], :unsupported_source_lane)

      true ->
        :ok
    end
  end

  defp validate_action_record_order_fields(action, path) do
    cond do
      not is_integer(action.legacy_index) or action.legacy_index <= 0 ->
        invalid_value(path ++ [field_segment("legacy_index")], :positive_integer_required)

      not is_nil(action.registry_order) and
          (not is_integer(action.registry_order) or action.registry_order < 0) ->
        invalid_value(
          path ++ [field_segment("registry_order")],
          :non_neg_integer_or_nil_required
        )

      true ->
        :ok
    end
  end

  defp validate_unique_action_identities(actions) do
    actions
    |> sort_actions()
    |> Enum.reduce_while({MapSet.new(), MapSet.new()}, fn action, {names, modules} ->
      cond do
        MapSet.member?(names, action.name) ->
          {:halt,
           {:error,
            [
              validation_diagnostic(
                :duplicate_identity,
                [field_segment("action_bindings"), identity_segment(action.name)],
                %{identity: action.name}
              )
            ]}}

        MapSet.member?(modules, action.module) ->
          {:halt,
           {:error,
            [
              validation_diagnostic(
                :duplicate_identity,
                [
                  field_segment("action_bindings"),
                  identity_segment(action.name),
                  field_segment("module")
                ],
                %{identity: module_string(action.module)}
              )
            ]}}

        true ->
          {:cont, {MapSet.put(names, action.name), MapSet.put(modules, action.module)}}
      end
    end)
    |> case do
      {%MapSet{}, %MapSet{}} -> :ok
      {:error, _diagnostics} = error -> error
    end
  end

  defp validate_unique_action_orders(actions) do
    actions
    |> sort_actions()
    |> Enum.reduce_while({MapSet.new(), MapSet.new()}, &validate_unique_action_order/2)
    |> case do
      {%MapSet{}, %MapSet{}} -> :ok
      {:error, _diagnostics} = error -> error
    end
  end

  defp validate_unique_action_order(action, {legacy_indices, registry_orders}) do
    cond do
      MapSet.member?(legacy_indices, action.legacy_index) ->
        {:halt, duplicate_action_order(action, :legacy_index, action.legacy_index)}

      not is_nil(action.registry_order) and
          MapSet.member?(registry_orders, action.registry_order) ->
        {:halt, duplicate_action_order(action, :registry_order, action.registry_order)}

      true ->
        {:cont, next_action_orders(action, legacy_indices, registry_orders)}
    end
  end

  defp next_action_orders(action, legacy_indices, registry_orders) do
    next_registry_orders =
      if is_nil(action.registry_order),
        do: registry_orders,
        else: MapSet.put(registry_orders, action.registry_order)

    {MapSet.put(legacy_indices, action.legacy_index), next_registry_orders}
  end

  defp duplicate_action_order(action, namespace, value) do
    {:error,
     [
       validation_diagnostic(
         :duplicate_order,
         [field_segment("action_bindings"), identity_segment(action.name)],
         %{identity: Atom.to_string(namespace) <> ":" <> Integer.to_string(value)}
       )
     ]}
  end

  defp validate_action(%ActionBinding{} = action) do
    with :ok <- validate_action_capability_shape(action),
         :ok <- validate_action_capability_values(action),
         nil <- invalid_action_digest_field(action),
         :ok <- validate_action_m0_digest(action) do
      :ok
    else
      {:error, _diagnostics} = error ->
        error

      field when is_binary(field) ->
        {:error,
         [
           validation_diagnostic(
             :invalid_value,
             [
               field_segment("action_bindings"),
               identity_segment(action.name),
               field_segment(field)
             ],
             %{reason: :lowercase_sha256_required}
           )
         ]}
    end
  end

  defp validate_action_m0_digest(%ActionBinding{} = action) do
    projection = %{
      "index" => action.legacy_index,
      "name" => action.name,
      "module" => module_string(action.module),
      "source_bucket" => m0_source_bucket(action.source_lane),
      "capability" => m0_capability_projection(action.normalized_capability),
      "input_schema_sha256" => action.input_schema_sha256,
      "output_schema_sha256" => action.output_schema_sha256
    }

    with {:ok, bytes} <- encode_json(projection) do
      expected = sha256(bytes)

      if action.m0_row_sha256 == expected do
        :ok
      else
        {:error,
         [
           validation_diagnostic(
             :digest_mismatch,
             [
               field_segment("action_bindings"),
               identity_segment(action.name),
               field_segment("m0_row_sha256")
             ],
             %{expected: expected, actual: action.m0_row_sha256}
           )
         ]}
      end
    end
  end

  defp m0_capability_projection(capability) do
    %{
      "app_id" => m0_atom_value(capability.app_id),
      "confirmation" => m0_atom_value(capability.confirmation),
      "execution_mode" => m0_atom_value(capability.execution_mode),
      "exposure" => m0_atom_value(capability.exposure),
      "notes" => capability.notes,
      "permission" => m0_atom_value(capability.permission),
      "plugin_id" => capability.plugin_id,
      "resumable?" => capability.resumable?,
      "retry_safety" => m0_atom_value(capability.retry_safety),
      "skill_backed?" => capability.skill_backed?
    }
  end

  defp m0_atom_value(nil), do: nil

  defp m0_atom_value(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp m0_source_bucket(:native_static), do: "static"
  defp m0_source_bucket(:legacy_plugin), do: "plugin_append"

  defp validate_action_capability_shape(%ActionBinding{
         name: name,
         normalized_capability: capability
       })
       when is_map(capability) do
    fields = Map.keys(capability)
    unknown = fields -- @capability_fields
    missing = @capability_fields -- fields

    cond do
      unknown != [] ->
        field = unknown |> Enum.map(&field_name/1) |> Enum.sort() |> hd()

        {:error,
         [
           validation_diagnostic(
             :unknown_field,
             [
               field_segment("action_bindings"),
               identity_segment(name),
               field_segment("normalized_capability"),
               field_segment(field)
             ],
             %{field: field}
           )
         ]}

      missing != [] ->
        field = missing |> Enum.map(&field_name/1) |> Enum.sort() |> hd()

        {:error,
         [
           validation_diagnostic(
             :missing_field,
             [
               field_segment("action_bindings"),
               identity_segment(name),
               field_segment("normalized_capability"),
               field_segment(field)
             ],
             %{field: field}
           )
         ]}

      true ->
        :ok
    end
  end

  defp validate_action_capability_shape(%ActionBinding{name: name, normalized_capability: value}) do
    {:error,
     [
       validation_diagnostic(
         :invalid_type,
         [
           field_segment("action_bindings"),
           identity_segment(name),
           field_segment("normalized_capability")
         ],
         %{expected: "map", actual: value_kind(value)}
       )
     ]}
  end

  defp validate_action_capability_values(%ActionBinding{
         name: name,
         normalized_capability: capability
       }) do
    checks = [
      {:app_id, "atom_or_nil", &atom_or_nil?/1},
      {:confirmation, "atom_or_nil", &atom_or_nil?/1},
      {:execution_mode, "atom", &proper_atom?/1},
      {:exposure, "agent_or_internal", &(&1 in [:agent, :internal])},
      {:notes, "string_or_nil", &(is_binary(&1) or is_nil(&1))},
      {:permission, "atom", &proper_atom?/1},
      {:plugin_id, "string_or_nil", &(is_binary(&1) or is_nil(&1))},
      {:resumable?, "boolean", &is_boolean/1},
      {:retry_safety, "atom", &proper_atom?/1},
      {:skill_backed?, "boolean", &is_boolean/1}
    ]

    case Enum.find(checks, fn {field, _expected, predicate} ->
           not predicate.(Map.fetch!(capability, field))
         end) do
      nil ->
        :ok

      {field, expected, _predicate} ->
        actual = Map.fetch!(capability, field)

        {:error,
         [
           validation_diagnostic(
             :invalid_type,
             [
               field_segment("action_bindings"),
               identity_segment(name),
               field_segment("normalized_capability"),
               field_segment(Atom.to_string(field))
             ],
             %{expected: expected, actual: value_kind(actual)}
           )
         ]}
    end
  end

  defp atom_or_nil?(nil), do: true
  defp atom_or_nil?(value), do: proper_atom?(value)

  defp proper_atom?(value),
    do: is_atom(value) and value not in [nil, true, false]

  defp invalid_action_digest_field(%ActionBinding{} = action) do
    Enum.find(["m0_row_sha256", "input_schema_sha256", "output_schema_sha256"], fn field ->
      not lowercase_sha256?(Map.fetch!(action, String.to_existing_atom(field)))
    end)
  end

  defp lowercase_sha256?(value) when is_binary(value), do: Regex.match?(@sha256_pattern, value)
  defp lowercase_sha256?(_value), do: false

  defp canonical_string?(value) when is_binary(value) do
    value != "" and String.valid?(value) and value == String.trim(value) and
      not Enum.any?(String.to_charlist(value), &(&1 in 0..0x1F or &1 == 0x7F))
  end

  defp canonical_string?(_value), do: false

  defp plain_string?(value) when is_binary(value) do
    String.valid?(value) and
      not Enum.any?(String.to_charlist(value), &(&1 in 0..0x1F or &1 == 0x7F))
  end

  defp plain_string?(_value), do: false

  defp module_string?(value) when is_binary(value),
    do: Regex.match?(@module_string_pattern, value)

  defp module_string?(_value), do: false

  defp validate_action_integrity(contributions, actions, aliases) do
    rows = owned_action_rows(contributions, include_aliases?: false)

    with :ok <- validate_action_row_owner_lanes(rows, actions, aliases),
         :ok <- validate_bindings_have_rows(actions, rows, aliases),
         :ok <- validate_rows_have_bindings(rows, actions, aliases) do
      :ok
    end
  end

  defp validate_action_row_owner_lanes(rows, actions, aliases) do
    rows
    |> Enum.sort_by(fn {_contribution, row} -> row_sort_key(row) end)
    |> Enum.reduce_while(:ok, &validate_action_row_owner_lane(&1, &2, actions, aliases))
  end

  defp validate_action_row_owner_lane({contribution, row}, :ok, actions, aliases) do
    actions
    |> Enum.find(&action_declaration_matches?(row, &1))
    |> validate_action_owner_lane_match(contribution, row, aliases)
  end

  defp validate_action_owner_lane_match(nil, _contribution, _row, _aliases), do: {:cont, :ok}

  defp validate_action_owner_lane_match(action, contribution, row, aliases) do
    case action_owner_lane_error(contribution, action, aliases) do
      nil ->
        {:cont, :ok}

      reason ->
        {:halt,
         invalid_value(
           row_path(contribution, row),
           reason,
           owner_ref(contribution.owner)
         )}
    end
  end

  defp action_owner_lane_error(
         %Contribution{owner: %Owner{kind: :compiled_pack}},
         %ActionBinding{source_lane: :native_static},
         _aliases
       ),
       do: nil

  defp action_owner_lane_error(
         %Contribution{owner: %Owner{kind: :legacy_plugin, id: owner_id}},
         %ActionBinding{
           source_lane: :legacy_plugin,
           normalized_capability: %{plugin_id: owner_id}
         },
         _aliases
       ),
       do: nil

  defp action_owner_lane_error(
         %Contribution{owner: %Owner{kind: :compiled_pack, id: target_id}},
         %ActionBinding{
           source_lane: :legacy_plugin,
           normalized_capability: %{plugin_id: source_id}
         },
         aliases
       ) do
    if deprecated_alias_target?(aliases, source_id, target_id),
      do: nil,
      else: :legacy_action_requires_deprecated_pack_alias
  end

  defp action_owner_lane_error(
         _contribution,
         %ActionBinding{source_lane: :native_static},
         _aliases
       ),
       do: :native_action_requires_compiled_owner

  defp action_owner_lane_error(
         _contribution,
         %ActionBinding{source_lane: :legacy_plugin},
         _aliases
       ),
       do: :legacy_action_requires_legacy_owner

  defp validate_bindings_have_rows(actions, rows, aliases) do
    actions
    |> sort_actions()
    |> Enum.reduce_while(:ok, &validate_binding_has_row(&1, &2, rows, aliases))
  end

  defp validate_binding_has_row(action, :ok, rows, aliases) do
    matching_rows =
      Enum.count(rows, fn {contribution, row} ->
        action_row_matches?(contribution, row, action, aliases)
      end)

    if matching_rows == 1 do
      {:cont, :ok}
    else
      {:halt,
       {:error,
        [
          validation_diagnostic(
            :invalid_value,
            [field_segment("action_bindings"), identity_segment(action.name)],
            %{reason: :missing_action_declaration}
          )
        ]}}
    end
  end

  defp validate_rows_have_bindings(rows, actions, aliases) do
    rows
    |> Enum.sort_by(fn {_contribution, row} -> row_sort_key(row) end)
    |> Enum.reduce_while(:ok, fn {contribution, row}, :ok ->
      if Enum.count(actions, &action_row_matches?(contribution, row, &1, aliases)) == 1 do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          [
            validation_diagnostic(
              :invalid_value,
              [
                field_segment("contributions"),
                identity_segment(row.owner_id),
                field_segment("callbacks"),
                field_segment("actions"),
                identity_segment(row.identity[:value])
              ],
              %{reason: :missing_effective_binding},
              owner_ref(contribution.owner)
            )
          ]}}
      end
    end)
  end

  defp owned_action_rows(contributions, opts) do
    include_aliases? = Keyword.fetch!(opts, :include_aliases?)

    for %Contribution{callbacks: callbacks} = contribution <- contributions,
        is_map(callbacks),
        contribution.compatibility.kind != :deprecated_alias,
        %Row{} = row <- Map.get(callbacks, :actions, []),
        include_aliases? or row.order[:namespace] != :alias_target do
      {contribution, row}
    end
  end

  defp action_row_matches?(
         %Contribution{} = contribution,
         %Row{} = row,
         %ActionBinding{} = action,
         aliases \\ []
       ) do
    action_declaration_matches?(row, action) and
      action_owner_matches?(contribution, action, aliases)
  end

  defp action_declaration_matches?(%Row{} = row, %ActionBinding{} = action) do
    payload =
      row.payload_schema
      |> RowSchemas.normalize!(%Input{
        payload: row.payload,
        source_authority: row.source_authority
      })
      |> RowSchemas.canonical_projection()

    effective_order = action.registry_order || action.legacy_index

    {:ok, action_authority} = action_authority_projection(action)

    payload["module"] == module_string(action.module) and
      payload["name"] == action.name and
      payload["registry_order"] == action.registry_order and
      row.order[:value] == effective_order and
      row.m0_payload_sha256 == action.m0_row_sha256 and
      row.source_authority == action_authority
  rescue
    _error in [ArgumentError, KeyError, MatchError] -> false
  end

  defp action_owner_matches?(
         %Contribution{
           owner: %Owner{kind: :legacy_plugin, id: owner_id}
         },
         %ActionBinding{
           source_lane: :legacy_plugin,
           normalized_capability: %{plugin_id: owner_id}
         },
         _aliases
       ),
       do: true

  defp action_owner_matches?(
         %Contribution{owner: %Owner{kind: :compiled_pack}},
         %ActionBinding{
           source_lane: :native_static
         },
         _aliases
       ),
       do: true

  defp action_owner_matches?(
         %Contribution{owner: %Owner{kind: :compiled_pack, id: target_id}},
         %ActionBinding{
           source_lane: :legacy_plugin,
           normalized_capability: %{plugin_id: source_id}
         },
         aliases
       ),
       do: deprecated_alias_target?(aliases, source_id, target_id)

  defp action_owner_matches?(_contribution, _action, _aliases), do: false

  defp deprecated_alias_target?(aliases, source_id, target_id) do
    Enum.count(aliases, fn
      %CompatibilityAlias{
        kind: :deprecated_alias,
        owner_id: ^source_id,
        target: %Target{kind: :contribution, owner_id: ^target_id, identity: ^target_id}
      } ->
        true

      _alias ->
        false
    end) == 1
  end

  defp validation_diagnostic(code, path, detail, owner \\ nil) do
    %ValidationDiagnostic{
      schema_version: 1,
      code: code,
      path: path,
      owner: owner,
      detail: detail
    }
  end

  defp invalid_value(path, reason, owner \\ nil),
    do: {:error, [validation_diagnostic(:invalid_value, path, %{reason: reason}, owner)]}

  defp invalid_type_at(path, expected, actual, owner \\ nil) do
    {:error,
     [
       validation_diagnostic(
         :invalid_type,
         path,
         %{expected: expected, actual: value_kind(actual)},
         owner
       )
     ]}
  end

  defp missing_field(path, field, owner \\ nil),
    do: {:error, [validation_diagnostic(:missing_field, path, %{field: field}, owner)]}

  defp unknown_field(path, field, owner \\ nil),
    do: {:error, [validation_diagnostic(:unknown_field, path, %{field: field}, owner)]}

  defp owner_mismatch(path, expected, actual, owner) do
    {:error,
     [
       validation_diagnostic(
         :owner_mismatch,
         path,
         %{expected: diagnostic_string(expected), actual: diagnostic_string(actual)},
         owner
       )
     ]}
  end

  defp diagnostic_string(nil), do: "nil"
  defp diagnostic_string(value) when is_binary(value), do: value
  defp diagnostic_string(value) when is_atom(value), do: Atom.to_string(value)
  defp diagnostic_string(value) when is_integer(value), do: Integer.to_string(value)
  defp diagnostic_string(_value), do: "<invalid>"

  defp validate_exact_struct_at(struct, module, path) do
    expected = Map.keys(module.__struct__())
    actual = Map.keys(struct)

    cond do
      missing =
          expected
          |> Enum.reject(&(&1 in actual))
          |> Enum.sort_by(&field_name/1)
          |> List.first() ->
        name = field_name(missing)
        missing_field(path ++ [field_segment(name)], name)

      unknown =
          actual
          |> Enum.reject(&(&1 in expected))
          |> Enum.sort_by(&field_name/1)
          |> List.first() ->
        name = field_name(unknown)
        unknown_field(path ++ [field_segment(name)], name)

      true ->
        :ok
    end
  end

  defp canonicalization_error_at(path, value_kind, owner \\ nil) do
    {:error,
     [
       validation_diagnostic(
         :canonicalization_rejected,
         path,
         %{value_kind: value_kind},
         owner
       )
     ]}
  end

  defp nested_schema_error(1, _path), do: :ok

  defp nested_schema_error(schema_version, path)
       when is_integer(schema_version) and schema_version >= 0 do
    {:error,
     [
       validation_diagnostic(
         :unsupported_schema_version,
         path,
         %{expected: 1, actual: schema_version}
       )
     ]}
  end

  defp nested_schema_error(schema_version, path) when is_integer(schema_version),
    do: invalid_value(path, :non_neg_integer_required)

  defp nested_schema_error(schema_version, path) do
    {:error,
     [
       validation_diagnostic(
         :invalid_type,
         path,
         %{expected: "non_neg_integer", actual: value_kind(schema_version)}
       )
     ]}
  end

  defp validate_lowercase_sha256(value, path) when is_binary(value) and byte_size(value) == 64 do
    if lowercase_sha256?(value), do: :ok, else: invalid_value(path, :lowercase_sha256_required)
  end

  defp validate_lowercase_sha256(value, path) when is_binary(value),
    do: invalid_value(path, :lowercase_sha256_required)

  defp validate_lowercase_sha256(value, path) do
    {:error,
     [
       validation_diagnostic(
         :invalid_type,
         path,
         %{expected: "lowercase_sha256", actual: value_kind(value)}
       )
     ]}
  end

  defp validate_target(%Target{} = target, path) do
    cond do
      exact_struct(target, Target) != :ok ->
        canonicalization_error_at(path, "target")

      target.schema_version != 1 ->
        nested_schema_error(target.schema_version, path ++ [field_segment("schema_version")])

      target.kind not in [:contribution, :action] ->
        invalid_value(path ++ [field_segment("kind")], :unsupported_target_kind)

      not canonical_string?(target.owner_id) ->
        invalid_value(path ++ [field_segment("owner_id")], :canonical_string_required)

      not canonical_string?(target.identity) ->
        invalid_value(path ++ [field_segment("identity")], :canonical_string_required)

      true ->
        :ok
    end
  end

  defp validate_target(value, path) do
    {:error,
     [
       validation_diagnostic(
         :invalid_type,
         path,
         %{expected: "Target", actual: value_kind(value)}
       )
     ]}
  end

  defp safe_identity(value) when is_binary(value), do: value
  defp safe_identity(_value), do: "<invalid-identity>"

  defp row_path(%Contribution{owner: %Owner{id: owner_id}}, %Row{} = row) do
    [
      field_segment("contributions"),
      identity_segment(owner_id),
      field_segment("callbacks"),
      field_segment(
        if(is_atom(row.kind), do: Atom.to_string(row.kind), else: "<invalid-callback>")
      ),
      identity_segment(safe_identity(row.identity[:value]))
    ]
  end

  defp field_segment(value),
    do: %PathSegment{schema_version: 1, kind: :field, value: value}

  defp index_segment(value),
    do: %PathSegment{schema_version: 1, kind: :index, value: value}

  defp identity_segment(value),
    do: %PathSegment{schema_version: 1, kind: :identity, value: value}

  defp behavior_projection(%Candidate{} = candidate) do
    with {:ok, contributions} <- project_contributions(candidate.contributions),
         {:ok, actions} <- project_actions(candidate.action_bindings),
         {:ok, aliases} <- project_aliases(candidate.compatibility_aliases),
         {:ok, diagnostics} <- project_diagnostics(candidate.compatibility_diagnostics) do
      {:ok,
       %{
         "schema_version" => candidate.schema_version,
         "contributions" => contributions,
         "effective_actions" => actions,
         "compatibility_aliases" => aliases,
         "compatibility_diagnostics" => diagnostics
       }}
    end
  end

  defp behavior_projection(%Snapshot{} = snapshot) do
    with {:ok, contributions} <- project_contributions(snapshot.contributions),
         {:ok, actions} <- project_actions(snapshot.effective_actions),
         {:ok, aliases} <- project_aliases(snapshot.compatibility_aliases),
         {:ok, diagnostics} <- project_diagnostics(snapshot.compatibility_diagnostics) do
      {:ok,
       %{
         "schema_version" => snapshot.schema_version,
         "contributions" => contributions,
         "effective_actions" => actions,
         "compatibility_aliases" => aliases,
         "compatibility_diagnostics" => diagnostics
       }}
    end
  end

  defp project_diagnostics(diagnostics) do
    diagnostics
    |> sort_diagnostics()
    |> Enum.reduce_while({:ok, []}, fn diagnostic, {:ok, projected} ->
      case project_diagnostic(diagnostic) do
        {:ok, value} -> {:cont, {:ok, [value | projected]}}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, _diagnostics} = error -> error
    end
  end

  defp project_aliases(aliases) do
    aliases
    |> sort_aliases()
    |> Enum.reduce_while({:ok, []}, fn compatibility_alias, {:ok, projected} ->
      case project_alias(compatibility_alias) do
        {:ok, value} -> {:cont, {:ok, [value | projected]}}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, _diagnostics} = error -> error
    end
  end

  defp project_alias(
         %CompatibilityAlias{
           schema_version: 1,
           kind: kind,
           owner_id: owner_id,
           target: %Target{} = target,
           module: module,
           authority_sha256: authority_sha256
         } = compatibility_alias
       ) do
    with :ok <- exact_struct(compatibility_alias, CompatibilityAlias),
         {:ok, target_projection} <- project_target(target) do
      {:ok,
       %{
         "schema_version" => 1,
         "kind" => Atom.to_string(kind),
         "owner_id" => owner_id,
         "target" => target_projection,
         "module" => if(is_nil(module), do: nil, else: module_string(module)),
         "authority_sha256" => authority_sha256
       }}
    else
      _reason -> canonicalization_error("compatibility_alias")
    end
  end

  defp project_alias(_compatibility_alias),
    do: canonicalization_error("compatibility_alias")

  defp sort_aliases(aliases), do: Enum.sort_by(aliases, &alias_sort_key/1)

  defp alias_sort_key(%CompatibilityAlias{} = compatibility_alias) do
    target = compatibility_alias.target

    {
      alias_kind_rank(compatibility_alias.kind),
      compatibility_alias.owner_id,
      target_kind_sort_value(target),
      target_owner_sort_value(target),
      target_identity_sort_value(target),
      module_sort_string(compatibility_alias.module)
    }
  end

  defp alias_sort_key(_compatibility_alias), do: {99, "", "", "", "", ""}

  defp alias_kind_rank(:legacy_plugin), do: 0
  defp alias_kind_rank(:deprecated_alias), do: 1
  defp alias_kind_rank(_kind), do: 99

  defp target_kind_sort_value(%Target{kind: kind}) when is_atom(kind), do: Atom.to_string(kind)
  defp target_kind_sort_value(_target), do: ""

  defp target_owner_sort_value(%Target{owner_id: owner_id}) when is_binary(owner_id),
    do: owner_id

  defp target_owner_sort_value(_target), do: ""

  defp target_identity_sort_value(%Target{identity: identity}) when is_binary(identity),
    do: identity

  defp target_identity_sort_value(_target), do: ""

  defp project_actions(actions) do
    actions
    |> sort_actions()
    |> Enum.reduce_while({:ok, []}, fn action, {:ok, projected} ->
      case project_action(action) do
        {:ok, value} -> {:cont, {:ok, [value | projected]}}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, _diagnostics} = error -> error
    end
  end

  defp project_action(
         %ActionBinding{
           schema_version: 1,
           module: module,
           name: name,
           source_lane: source_lane,
           legacy_index: legacy_index,
           registry_order: registry_order,
           normalized_capability: capability,
           m0_row_sha256: m0_row_sha256,
           input_schema_sha256: input_schema_sha256,
           output_schema_sha256: output_schema_sha256
         } = action
       ) do
    with :ok <- exact_struct(action, ActionBinding),
         {:ok, capability_projection} <- project_capability(capability) do
      {:ok,
       %{
         "schema_version" => 1,
         "module" => module_string(module),
         "name" => name,
         "source_lane" => Atom.to_string(source_lane),
         "legacy_index" => legacy_index,
         "registry_order" => registry_order,
         "normalized_capability" => capability_projection,
         "m0_row_sha256" => m0_row_sha256,
         "input_schema_sha256" => input_schema_sha256,
         "output_schema_sha256" => output_schema_sha256
       }}
    else
      _reason -> canonicalization_error("action_binding")
    end
  end

  defp project_action(_action), do: canonicalization_error("action_binding")

  defp project_capability(
         %{
           app_id: app_id,
           confirmation: confirmation,
           execution_mode: execution_mode,
           exposure: exposure,
           notes: notes,
           permission: permission,
           plugin_id: plugin_id,
           resumable?: resumable?,
           retry_safety: retry_safety,
           skill_backed?: skill_backed?
         } = capability
       )
       when map_size(capability) == 10 do
    {:ok,
     %{
       "app_id" => atom_string(app_id),
       "confirmation" => atom_string(confirmation),
       "execution_mode" => atom_string(execution_mode),
       "exposure" => atom_string(exposure),
       "notes" => notes,
       "permission" => atom_string(permission),
       "plugin_id" => plugin_id,
       "resumable?" => resumable?,
       "retry_safety" => atom_string(retry_safety),
       "skill_backed?" => skill_backed?
     }}
  end

  defp project_capability(_capability), do: canonicalization_error("normalized_capability")

  defp sort_actions(actions), do: Enum.sort_by(actions, &action_sort_key/1)

  defp action_sort_key(%ActionBinding{} = action) do
    {action.registry_order || action.legacy_index, module_sort_string(action.module), action.name}
  end

  defp action_sort_key(_action), do: {0, "", ""}

  defp project_diagnostic(
         %CompatibilityDiagnostic{
           schema_version: 1,
           code: code,
           severity: severity,
           path: path,
           owner: owner,
           detail: detail
         } = diagnostic
       ) do
    with :ok <- exact_struct(diagnostic, CompatibilityDiagnostic),
         {:ok, path_projection} <- project_path(path),
         {:ok, owner_projection} <- project_owner_ref(owner),
         {:ok, detail_projection} <- project_diagnostic_detail(code, detail) do
      {:ok,
       %{
         "schema_version" => 1,
         "code" => Atom.to_string(code),
         "severity" => Atom.to_string(severity),
         "path" => path_projection,
         "owner" => owner_projection,
         "detail" => detail_projection
       }}
    else
      _reason -> canonicalization_error("compatibility_diagnostic")
    end
  end

  defp project_diagnostic(_diagnostic),
    do: canonicalization_error("compatibility_diagnostic")

  defp project_path(path) when is_list(path) do
    path
    |> Enum.reduce_while({:ok, []}, fn
      %PathSegment{schema_version: 1, kind: kind, value: value} = segment, {:ok, projected} ->
        if exact_struct(segment, PathSegment) == :ok do
          {:cont,
           {:ok,
            [
              %{"schema_version" => 1, "kind" => Atom.to_string(kind), "value" => value}
              | projected
            ]}}
        else
          {:halt, canonicalization_error("path_segment")}
        end

      _segment, _accumulator ->
        {:halt, canonicalization_error("path_segment")}
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, _diagnostics} = error -> error
    end
  end

  defp project_path(_path), do: canonicalization_error("path")

  defp project_owner_ref(nil), do: {:ok, nil}

  defp project_owner_ref(%OwnerRef{schema_version: 1, kind: kind, id: id} = owner) do
    if exact_struct(owner, OwnerRef) == :ok do
      {:ok, %{"schema_version" => 1, "kind" => Atom.to_string(kind), "id" => id}}
    else
      canonicalization_error("owner_ref")
    end
  end

  defp project_owner_ref(_owner), do: canonicalization_error("owner_ref")

  defp project_diagnostic_detail(
         :legacy_registry,
         %{
           source_lane: source_lane,
           legacy_index: legacy_index
         } = detail
       )
       when map_size(detail) == 2 and is_atom(source_lane) and is_integer(legacy_index) do
    {:ok, %{"source_lane" => Atom.to_string(source_lane), "legacy_index" => legacy_index}}
  end

  defp project_diagnostic_detail(:disabled_plugin, %{source: source, status: :disabled} = detail)
       when map_size(detail) == 2 and is_atom(source) do
    {:ok, %{"source" => Atom.to_string(source), "status" => "disabled"}}
  end

  defp project_diagnostic_detail(
         :deprecated_alias,
         %{
           alias_kind: alias_kind,
           target: %Target{} = target
         } = detail
       )
       when map_size(detail) == 2 and is_atom(alias_kind) do
    with {:ok, target_projection} <- project_target(target) do
      {:ok, %{"alias_kind" => Atom.to_string(alias_kind), "target" => target_projection}}
    end
  end

  defp project_diagnostic_detail(
         :child_spec,
         %{
           child_spec: %ChildSpecProjection{} = child_spec
         } = detail
       )
       when map_size(detail) == 1 do
    with {:ok, child_projection} <- project_child_spec(child_spec) do
      {:ok, %{"child_spec" => child_projection}}
    end
  end

  defp project_diagnostic_detail(
         :collision,
         %{identity: identity, participants: participants} = detail
       )
       when map_size(detail) == 2 and is_binary(identity) and is_list(participants) do
    with {:ok, target_projections} <- project_targets(participants) do
      {:ok,
       %{
         "identity" => identity,
         "participants" => Enum.sort_by(target_projections, &target_projection_sort_key/1)
       }}
    end
  end

  defp project_diagnostic_detail(_code, _detail),
    do: canonicalization_error("compatibility_diagnostic_detail")

  defp project_targets(targets) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, projected} ->
      case project_target(target) do
        {:ok, value} -> {:cont, {:ok, [value | projected]}}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, _diagnostics} = error -> error
    end
  end

  defp project_target(
         %Target{schema_version: 1, kind: kind, owner_id: owner_id, identity: identity} = target
       ) do
    if exact_struct(target, Target) == :ok do
      {:ok,
       %{
         "schema_version" => 1,
         "kind" => Atom.to_string(kind),
         "owner_id" => owner_id,
         "identity" => identity
       }}
    else
      canonicalization_error("target")
    end
  end

  defp project_target(_target), do: canonicalization_error("target")

  defp project_child_spec(%ChildSpecProjection{} = child_spec) do
    if exact_struct(child_spec, ChildSpecProjection) == :ok do
      {:ok,
       %{
         "schema_version" => child_spec.schema_version,
         "id" => child_spec.id,
         "start_module" => child_spec.start_module,
         "start_function" => child_spec.start_function,
         "start_arity" => child_spec.start_arity,
         "start_args_sha256" => child_spec.start_args_sha256,
         "restart" => child_spec.restart,
         "shutdown" => child_spec.shutdown,
         "type" => child_spec.type
       }}
    else
      canonicalization_error("child_spec_projection")
    end
  end

  defp target_projection_sort_key(target),
    do: {target["kind"], target["owner_id"], target["identity"]}

  defp sort_diagnostics(diagnostics), do: Enum.sort_by(diagnostics, &diagnostic_sort_key/1)

  defp diagnostic_sort_key(%CompatibilityDiagnostic{} = diagnostic) do
    {
      severity_rank(diagnostic.severity),
      Atom.to_string(diagnostic.code),
      canonical_sort_bytes(diagnostic.path),
      owner_ref_sort_key(diagnostic.owner),
      canonical_sort_bytes(diagnostic.detail)
    }
  end

  defp diagnostic_sort_key(_diagnostic), do: {99, "", "", {99, ""}, ""}

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(_severity), do: 99

  defp owner_ref_sort_key(nil), do: {-1, ""}

  defp owner_ref_sort_key(%OwnerRef{kind: kind, id: id}),
    do: {owner_kind_rank(kind), id}

  defp owner_ref_sort_key(_owner), do: {99, ""}

  defp canonical_sort_bytes(value) do
    case normalize_sort_value(value) |> encode_json() do
      {:ok, bytes} -> bytes
      {:error, _reason} -> <<255>>
    end
  end

  defp normalize_sort_value(%PathSegment{} = segment) do
    %{
      "schema_version" => segment.schema_version,
      "kind" => atom_string(segment.kind),
      "value" => segment.value
    }
  end

  defp normalize_sort_value(%Target{} = target) do
    %{
      "schema_version" => target.schema_version,
      "kind" => atom_string(target.kind),
      "owner_id" => target.owner_id,
      "identity" => target.identity
    }
  end

  defp normalize_sort_value(%ChildSpecProjection{} = child_spec) do
    child_spec
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), normalize_sort_value(value)} end)
  end

  defp normalize_sort_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {field_name(key), normalize_sort_value(nested)} end)
  end

  defp normalize_sort_value(value) when is_list(value),
    do: Enum.map(value, &normalize_sort_value/1)

  defp normalize_sort_value(value) when is_atom(value), do: atom_string(value)
  defp normalize_sort_value(value), do: value

  defp project_contributions(contributions) do
    contributions
    |> sort_contributions()
    |> Enum.reduce_while({:ok, []}, fn contribution, {:ok, projected} ->
      case project_contribution(contribution) do
        {:ok, value} -> {:cont, {:ok, [value | projected]}}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, _diagnostics} = error -> error
    end
  end

  defp project_contribution(
         %Contribution{
           schema_version: 1,
           owner: %Owner{} = owner,
           descriptor: descriptor,
           implementation_module: implementation_module,
           source_lane: source_lane,
           owner_order: %Order{} = owner_order,
           compatibility: %Compatibility{} = compatibility,
           callbacks: callbacks
         } = contribution
       ) do
    with :ok <- exact_struct(contribution, Contribution),
         :ok <- exact_struct(owner, Owner),
         :ok <- exact_struct(owner_order, Order),
         :ok <- exact_struct(compatibility, Compatibility),
         {:ok, descriptor_projection} <- project_descriptor(descriptor),
         {:ok, callbacks_projection} <- project_callbacks(callbacks, contribution) do
      {:ok,
       %{
         "schema_version" => 1,
         "owner" => %{
           "schema_version" => owner.schema_version,
           "kind" => Atom.to_string(owner.kind),
           "id" => owner.id,
           "application" => atom_string(owner.application)
         },
         "descriptor" => descriptor_projection,
         "implementation_module" =>
           if(is_nil(implementation_module), do: nil, else: module_string(implementation_module)),
         "source_lane" => Atom.to_string(source_lane),
         "owner_order" => %{
           "schema_version" => owner_order.schema_version,
           "namespace" => Atom.to_string(owner_order.namespace),
           "value" => owner_order.value
         },
         "compatibility" => %{
           "schema_version" => compatibility.schema_version,
           "kind" => Atom.to_string(compatibility.kind),
           "legacy_id" => compatibility.legacy_id,
           "alias_of" => project_target_value(compatibility.alias_of),
           "trust" => Atom.to_string(compatibility.trust),
           "enabled" => compatibility.enabled
         },
         "callbacks" => callbacks_projection
       }}
    else
      {:error, [%ValidationDiagnostic{} | _diagnostics]} = error -> error
      _reason -> canonicalization_error("contribution")
    end
  end

  defp project_contribution(_contribution), do: canonicalization_error("contribution")

  defp project_descriptor(nil), do: {:ok, nil}

  defp project_descriptor(%Descriptor{} = descriptor) do
    with :ok <- exact_struct(descriptor, Descriptor),
         {:ok, ^descriptor} <- Descriptor.validate(descriptor) do
      {:ok,
       %{
         "schema_version" => descriptor.schema_version,
         "id" => descriptor.id,
         "application" => atom_string(descriptor.application),
         "application_version" => descriptor.application_version,
         "capability_tier" => atom_string(descriptor.capability_tier),
         "provenance" => %{
           "source" => atom_string(descriptor.provenance.source),
           "component" => descriptor.provenance.component
         },
         "registry_order" => descriptor.registry_order
       }}
    else
      _reason -> canonicalization_error("descriptor")
    end
  end

  defp project_descriptor(_descriptor), do: canonicalization_error("descriptor")

  defp project_callbacks(callbacks, %Contribution{} = contribution) when is_map(callbacks) do
    callback_order = RowSchemas.callback_order()

    if Enum.sort(Map.keys(callbacks)) == Enum.sort(callback_order) do
      Enum.reduce_while(
        callback_order,
        {:ok, %{}},
        &project_callback(&1, &2, callbacks, contribution)
      )
    else
      canonicalization_error("callbacks")
    end
  end

  defp project_callbacks(_callbacks, _contribution), do: canonicalization_error("callbacks")

  defp project_callback(callback, {:ok, projected}, callbacks, contribution) do
    case project_rows(Map.fetch!(callbacks, callback), contribution, callback) do
      {:ok, rows} ->
        {:cont, {:ok, Map.put(projected, Atom.to_string(callback), rows)}}

      {:error, _diagnostics} = error ->
        {:halt, error}
    end
  end

  defp project_rows(rows, %Contribution{} = contribution, callback) when is_list(rows) do
    rows
    |> Enum.sort_by(&row_sort_key/1)
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, projected} ->
      case project_row(row, contribution, callback) do
        {:ok, value} -> {:cont, {:ok, [value | projected]}}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, _diagnostics} = error -> error
    end
  end

  defp project_rows(_rows, _contribution, _callback), do: canonicalization_error("rows")

  defp project_row(%Row{kind: callback} = row, %Contribution{} = contribution, callback) do
    try do
      :ok = exact_struct(row, Row)
      _authority = RowSchemas.alias_authority_projection!(row, contribution)

      normalized =
        row.payload_schema
        |> RowSchemas.normalize!(%Input{
          payload: row.payload,
          source_authority: row.source_authority
        })

      payload = RowSchemas.canonical_projection(normalized)
      source_authority = RowSchemas.source_authority_projection(normalized)

      with :ok <- validate_projected_row_semantics(row, contribution, payload) do
        {:ok,
         %{
           "schema_version" => row.schema_version,
           "kind" => Atom.to_string(row.kind),
           "owner_id" => row.owner_id,
           "identity" => %{
             "namespace" => Atom.to_string(row.identity.namespace),
             "value" => row.identity.value
           },
           "order" => %{
             "namespace" => Atom.to_string(row.order.namespace),
             "value" => row.order.value
           },
           "payload_schema" => Atom.to_string(row.payload_schema),
           "payload" => payload,
           "source_authority" => source_authority,
           "m0_payload_sha256" => row.m0_payload_sha256
         }}
      end
    rescue
      _error in [ArgumentError, MatchError, KeyError] ->
        row_canonicalization_error(row, contribution, callback)
    end
  end

  defp project_row(%Row{} = row, %Contribution{} = contribution, callback),
    do: row_canonicalization_error(row, contribution, callback)

  defp project_row(_row, _contribution, _callback), do: canonicalization_error("row")

  defp validate_projected_row_semantics(
         %Row{kind: :skill_roots} = row,
         %Contribution{
           owner: %Owner{kind: owner_kind},
           compatibility: %Compatibility{trust: trust}
         } = contribution,
         payload
       )
       when owner_kind in [:legacy_plugin, :declared_pack] do
    expected_trust = Atom.to_string(trust)
    actual_trust = Map.fetch!(payload, "trust_policy")

    if actual_trust == expected_trust do
      validate_declared_skill_root_namespace(row, contribution, payload)
    else
      row_payload_error(
        row,
        contribution,
        "trust_policy",
        :skill_root_trust_mismatch
      )
    end
  end

  defp validate_projected_row_semantics(_row, _contribution, _payload), do: :ok

  defp validate_declared_skill_root_namespace(
         %Row{} = row,
         %Contribution{owner: %Owner{kind: :declared_pack, id: owner_id}} = contribution,
         payload
       ) do
    owner_prefix = "plugins/" <> owner_id
    relative_path = Map.fetch!(payload, "relative_path")
    root_id = Map.fetch!(payload, "root_id")
    expected_root_id = owner_id <> ":" <> relative_path

    cond do
      relative_path != owner_prefix and
          not String.starts_with?(relative_path, owner_prefix <> "/") ->
        row_payload_error(
          row,
          contribution,
          "relative_path",
          :declared_skill_root_path_mismatch
        )

      root_id != expected_root_id ->
        row_payload_error(
          row,
          contribution,
          "root_id",
          :declared_skill_root_id_mismatch
        )

      true ->
        :ok
    end
  end

  defp validate_declared_skill_root_namespace(_row, _contribution, _payload), do: :ok

  defp row_payload_error(%Row{} = row, %Contribution{} = contribution, field, reason) do
    invalid_value(
      row_path(contribution, row) ++ [field_segment("payload"), field_segment(field)],
      reason,
      owner_ref(contribution.owner)
    )
  end

  defp row_canonicalization_error(
         %Row{} = row,
         %Contribution{owner: %Owner{} = contribution_owner},
         callback
       ) do
    callback_name = if is_atom(callback), do: Atom.to_string(callback), else: "<invalid-callback>"

    identity =
      case row.identity do
        %{value: value} when is_binary(value) -> value
        _identity -> "<invalid-row>"
      end

    {:error,
     [
       validation_diagnostic(
         :canonicalization_rejected,
         [
           field_segment("contributions"),
           identity_segment(contribution_owner.id),
           field_segment("callbacks"),
           field_segment(callback_name),
           identity_segment(identity)
         ],
         %{value_kind: "row"},
         owner_ref(contribution_owner)
       )
     ]}
  end

  defp row_sort_key(%Row{} = row) do
    {
      order_namespace_rank(row.order[:namespace]),
      row.order[:value],
      atom_string(row.identity[:namespace]),
      row.identity[:value],
      canonical_sort_bytes(row.payload)
    }
  end

  defp row_sort_key(_row), do: {99, 0, "", "", ""}

  defp order_namespace_rank(:legacy_index), do: 0
  defp order_namespace_rank(:registry_order), do: 1
  defp order_namespace_rank(:alias_target), do: 2
  defp order_namespace_rank(:lexical), do: 3
  defp order_namespace_rank(_namespace), do: 99

  defp contribution_sort_key(%Contribution{
         owner_order: %Order{} = order,
         owner: %Owner{} = owner
       }) do
    {owner_namespace_rank(order.namespace), order.value, owner.id, atom_string(owner.application)}
  end

  defp contribution_sort_key(_contribution), do: {99, 0, "", ""}

  defp sort_contributions(contributions),
    do: Enum.sort_by(contributions, &contribution_sort_key/1)

  defp owner_namespace_rank(:compiled_pack), do: 0
  defp owner_namespace_rank(:legacy_plugin), do: 1
  defp owner_namespace_rank(:declared_pack), do: 2
  defp owner_namespace_rank(_namespace), do: 99

  defp owner_kind_rank(:compiled_pack), do: 0
  defp owner_kind_rank(:legacy_plugin), do: 1
  defp owner_kind_rank(:declared_pack), do: 2
  defp owner_kind_rank(_kind), do: 99

  defp exact_struct(struct, module) do
    if Enum.sort(Map.keys(struct)) == Enum.sort(Map.keys(module.__struct__())),
      do: :ok,
      else: :error
  end

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)

  defp module_string(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp module_sort_string(value) when is_atom(value), do: module_string(value)
  defp module_sort_string(_value), do: ""

  defp project_target_value(nil), do: nil

  defp project_target_value(%Target{} = target) do
    case project_target(target) do
      {:ok, projection} -> projection
      {:error, _diagnostics} -> nil
    end
  end

  defp project_target_value(_target), do: nil

  defp canonicalization_error(value_kind) do
    {:error,
     [
       validation_diagnostic(
         :canonicalization_rejected,
         [],
         %{value_kind: value_kind}
       )
     ]}
  end

  defp encode_json(value) when is_map(value) do
    if Enum.all?(Map.keys(value), &is_binary/1) do
      encode_json_object(value)
    else
      canonicalization_error("map_key")
    end
  end

  defp encode_json(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn nested, {:ok, encoded} ->
      case encode_json(nested) do
        {:ok, bytes} -> {:cont, {:ok, [bytes | encoded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} ->
        {:ok, IO.iodata_to_binary(["[", encoded |> Enum.reverse() |> Enum.intersperse(","), "]"])}

      {:error, _reason} = error ->
        error
    end
  end

  defp encode_json(value) when is_binary(value), do: encode_string(value)
  defp encode_json(value) when is_integer(value), do: {:ok, Integer.to_string(value)}

  defp encode_json(value) when is_float(value) do
    encoded = :erlang.float_to_binary(value, [:short])

    if String.contains?(encoded, ["nan", "inf"]),
      do: canonicalization_error("non_finite_float"),
      else: {:ok, encoded}
  end

  defp encode_json(true), do: {:ok, "true"}
  defp encode_json(false), do: {:ok, "false"}
  defp encode_json(nil), do: {:ok, "null"}
  defp encode_json(value), do: canonicalization_error(value_kind(value))

  defp encode_json_object(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, &encode_json_member/2)
    |> finish_json_object()
  end

  defp encode_json_member({key, nested}, {:ok, encoded}) do
    with {:ok, encoded_key} <- encode_string(key),
         {:ok, encoded_value} <- encode_json(nested) do
      {:cont, {:ok, [[encoded_key, ":", encoded_value] | encoded]}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp finish_json_object({:ok, encoded}) do
    members = encoded |> Enum.reverse() |> Enum.intersperse(",")
    {:ok, IO.iodata_to_binary(["{", members, "}"])}
  end

  defp finish_json_object({:error, _reason} = error), do: error

  defp encode_string(value) do
    if String.valid?(value) do
      escaped =
        value
        |> String.to_charlist()
        |> Enum.map(&escape_codepoint/1)

      {:ok, IO.iodata_to_binary([?\", escaped, ?\"])}
    else
      canonicalization_error("string")
    end
  end

  defp escape_codepoint(?\"), do: "\\\""
  defp escape_codepoint(?\\), do: "\\\\"
  defp escape_codepoint(?\b), do: "\\b"
  defp escape_codepoint(?\f), do: "\\f"
  defp escape_codepoint(?\n), do: "\\n"
  defp escape_codepoint(?\r), do: "\\r"
  defp escape_codepoint(?\t), do: "\\t"

  defp escape_codepoint(codepoint) when codepoint < 0x20 do
    ["\\u", codepoint |> Integer.to_string(16) |> String.pad_leading(4, "0")]
  end

  defp escape_codepoint(codepoint), do: <<codepoint::utf8>>

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
