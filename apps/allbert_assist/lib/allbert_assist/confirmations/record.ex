defmodule AllbertAssist.Confirmations.Record do
  @moduledoc false

  alias AllbertAssist.Runtime.Redactor

  @pending_status "pending"
  @statuses ~w(pending approved denied expired cancelled adapter_unavailable)
  @system_integrity_ref "secret://system/integrity_v1"
  @objective_binding_version 2
  @objective_binding_kinds ~w(ordinary objective fanout_child)

  @required_string_fields ~w(id status requested_at expires_at)
  @required_map_fields ~w(origin target_action security_decision params_summary)

  @doc "Build a validated pending confirmation record."
  def new(attrs, now, ttl_minutes, objective_binding_kind \\ "ordinary")
      when is_map(attrs) and is_integer(ttl_minutes) do
    now = DateTime.truncate(now, :second)
    expires_at = DateTime.add(now, ttl_minutes * 60, :second)
    id = value(attrs, :id) || generate_id(now)

    record =
      %{
        "id" => id,
        "status" => @pending_status,
        "requested_at" => DateTime.to_iso8601(now),
        "expires_at" => DateTime.to_iso8601(expires_at),
        "resolved_at" => nil,
        "origin" => redacted_map(value(attrs, :origin, %{})),
        "target_action" => target_action(attrs),
        "target_permission" => stringify(value(attrs, :target_permission)),
        "target_execution_mode" => stringify(value(attrs, :target_execution_mode)),
        "selected_skill" => redacted_map(value(attrs, :selected_skill, %{})),
        "capability_contract" => redacted_map(value(attrs, :capability_contract, %{})),
        "security_decision" => redacted_map(value(attrs, :security_decision, %{})),
        "source_signal_id" => stringify(value(attrs, :source_signal_id)),
        "source_trace_id" => stringify(value(attrs, :source_trace_id)),
        "objective_binding_version" => @objective_binding_version,
        "objective_binding_kind" => stringify(objective_binding_kind),
        "objective_id" => stringify(value(attrs, :objective_id)),
        "step_id" => stringify(value(attrs, :step_id)),
        "runner_metadata" => redacted_map(value(attrs, :runner_metadata, %{})),
        "params_summary" => redacted_map(value(attrs, :params_summary, %{})),
        "resume_params_ref" => redacted_map(value(attrs, :resume_params_ref, %{})),
        "operator_resolution" => nil,
        "audit_path" => stringify(value(attrs, :audit_path))
      }
      |> drop_nil_values()

    with :ok <- validate(record) do
      {:ok, record}
    end
  end

  @doc "Build a resolved record from a pending record."
  def resolve(record, status, resolution_attrs, now)
      when is_map(record) and is_map(resolution_attrs) do
    status = status_string(status)
    now = DateTime.truncate(now, :second)

    resolved =
      record
      |> Map.put("status", status)
      |> Map.put("resolved_at", DateTime.to_iso8601(now))
      |> Map.put("operator_resolution", operator_resolution(resolution_attrs, now))

    with :ok <- validate(resolved) do
      {:ok, resolved}
    end
  end

  @doc "Validate the persisted confirmation record shape."
  def validate(record) when is_map(record) do
    with :ok <- validate_required_strings(record),
         :ok <- validate_required_maps(record),
         :ok <- validate_status(Map.get(record, "status")),
         :ok <- validate_objective_binding(record),
         :ok <- validate_datetime(record, "requested_at"),
         :ok <- validate_datetime(record, "expires_at"),
         :ok <- validate_optional_datetime(record, "resolved_at") do
      :ok
    end
  end

  def validate(_record), do: {:error, {:invalid_confirmation_record, :not_a_map}}

  @doc "Return true when a pending record expired at or before now."
  def expired?(record, now) when is_map(record) do
    with {:ok, expires_at} <- parse_datetime(Map.get(record, "expires_at")) do
      DateTime.compare(expires_at, now) in [:lt, :eq]
    else
      _error -> false
    end
  end

  def pending_status, do: @pending_status
  def statuses, do: @statuses

  defp validate_required_strings(record) do
    Enum.reduce_while(@required_string_fields, :ok, fn field, :ok ->
      case Map.get(record, field) do
        value when is_binary(value) and value != "" -> {:cont, :ok}
        value -> {:halt, {:error, {:invalid_confirmation_record, {field, value}}}}
      end
    end)
  end

  defp validate_required_maps(record) do
    Enum.reduce_while(@required_map_fields, :ok, fn field, :ok ->
      case Map.get(record, field) do
        value when is_map(value) -> {:cont, :ok}
        value -> {:halt, {:error, {:invalid_confirmation_record, {field, value}}}}
      end
    end)
  end

  defp validate_status(status) when status in @statuses, do: :ok
  defp validate_status(status), do: {:error, {:invalid_confirmation_status, status}}

  # Unversioned records written before the binding contract, including the
  # first M12.15 candidate, remain readable. So does the short-lived local v1
  # transition shape. Only v2 carries an explicit internally derived kind;
  # that kind keeps ordinary confirmations off the Objectives store while
  # fan-out confirmations retain exact durable provenance checks.
  defp validate_objective_binding(record) do
    version = Map.get(record, "objective_binding_version")
    kind = Map.get(record, "objective_binding_kind")

    case {version, kind} do
      {nil, nil} ->
        :ok

      {1, nil} ->
        :ok

      {@objective_binding_version, kind} when kind in @objective_binding_kinds ->
        validate_current_binding_shape(record, kind)

      {@objective_binding_version, kind} ->
        {:error, {:invalid_confirmation_record, {"objective_binding_kind", kind}}}

      {version, _kind} ->
        {:error, {:invalid_confirmation_record, {"objective_binding_version", version}}}
    end
  end

  defp validate_current_binding_shape(record, "ordinary") do
    if parent_bound?(record) or complete_objective_binding?(record) or
         orphan_step_binding?(record),
       do: invalid_binding_kind("ordinary"),
       else: :ok
  end

  defp validate_current_binding_shape(record, "objective") do
    if complete_objective_binding?(record) and not parent_bound?(record),
      do: :ok,
      else: invalid_binding_kind("objective")
  end

  defp validate_current_binding_shape(record, "fanout_child") do
    if complete_objective_binding?(record) and parent_bound?(record) and binding_user?(record) and
         target_action_bound?(record),
       do: :ok,
       else: invalid_binding_kind("fanout_child")
  end

  defp complete_objective_binding?(record) do
    present_string?(Map.get(record, "objective_id")) and
      present_string?(Map.get(record, "step_id"))
  end

  defp orphan_step_binding?(record) do
    present_string?(Map.get(record, "step_id")) and
      not present_string?(Map.get(record, "objective_id"))
  end

  defp parent_bound?(record) do
    record
    |> Map.get("origin", %{})
    |> Map.get("parent_objective_id")
    |> present_string?()
  end

  defp binding_user?(record) do
    record
    |> Map.get("origin", %{})
    |> Map.get("user_id")
    |> present_string?()
  end

  defp target_action_bound?(record) do
    record
    |> Map.get("target_action", %{})
    |> Map.get("name")
    |> present_string?()
  end

  defp present_string?(value), do: is_binary(value) and value != ""

  defp invalid_binding_kind(kind),
    do: {:error, {:invalid_confirmation_record, {"objective_binding_kind", kind}}}

  defp validate_datetime(record, field) do
    case parse_datetime(Map.get(record, field)) do
      {:ok, _datetime} -> :ok
      {:error, reason} -> {:error, {:invalid_confirmation_datetime, field, reason}}
    end
  end

  defp validate_optional_datetime(record, field) do
    case Map.get(record, field) do
      nil -> :ok
      value when is_binary(value) -> validate_datetime(record, field)
      value -> {:error, {:invalid_confirmation_datetime, field, value}}
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_datetime(value), do: {:error, value}

  defp operator_resolution(attrs, now) do
    %{
      "resolver_actor" => stringify(value(attrs, :resolver_actor)),
      "resolver_channel" => stringify(value(attrs, :resolver_channel)),
      "resolver_surface" => stringify(value(attrs, :resolver_surface)),
      "resolver_session_id" => stringify(value(attrs, :resolver_session_id)),
      "resolution_reason" => stringify(value(attrs, :resolution_reason)),
      "same_channel?" => value(attrs, :same_channel?, false),
      "decision_source" => stringify(value(attrs, :decision_source, "operator")),
      "resolver_metadata" => redacted_value(value(attrs, :resolver_metadata)),
      "resolved_at" => DateTime.to_iso8601(now)
    }
    |> Map.merge(operator_target_resolution(attrs))
    |> drop_nil_values()
    |> Redactor.redact()
  end

  defp operator_target_resolution(attrs) do
    %{
      "target_resumed?" => value(attrs, :target_resumed?),
      "target_status" => stringify(value(attrs, :target_status)),
      "target_result" => target_result(value(attrs, :target_result)),
      "target_async?" => value(attrs, :target_async?),
      "remembered_grants" => redacted_value(value(attrs, :remembered_grants)),
      "adapter_unavailable?" => value(attrs, :adapter_unavailable?)
    }
  end

  defp target_result(value) when is_map(value), do: redacted_map(value)
  defp target_result(_value), do: nil

  defp redacted_value(value) when is_map(value), do: redacted_map(value)
  defp redacted_value(value) when is_list(value), do: map_list(value, &redacted_value/1)
  defp redacted_value(nil), do: nil
  defp redacted_value(value), do: stringify_value(value)

  defp target_action(attrs) do
    attrs
    |> value(:target_action, %{})
    |> case do
      value when is_map(value) -> redacted_map(value)
      value -> %{"name" => stringify(value)}
    end
  end

  defp redacted_map(value) when is_map(value) do
    stringified = stringify_keys(value)

    stringified
    |> Redactor.redact()
    |> preserve_system_integrity_ref(stringified)
  end

  defp redacted_map(_value), do: %{}

  # The system-integrity reference names native HMAC custody; it is not key
  # material. Preserve only this closed value so resumable confirmations can
  # verify their bindings while provider and user secret refs remain redacted.
  defp preserve_system_integrity_ref(redacted, %{"key_ref" => @system_integrity_ref}) do
    Map.put(redacted, "key_ref", @system_integrity_ref)
  end

  defp preserve_system_integrity_ref(redacted, _original), do: redacted

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} ->
        {to_string(key), stringify_nested_value(value)}
    end)
  end

  defp stringify_nested_value(value) when is_map(value), do: stringify_keys(value)

  defp stringify_nested_value(value) when is_list(value),
    do: map_list(value, &stringify_nested_value/1)

  defp stringify_nested_value(value), do: stringify_value(value)

  defp map_list([head | tail], fun) when is_list(tail), do: [fun.(head) | map_list(tail, fun)]
  defp map_list([head | tail], fun), do: [fun.(head), fun.(tail)]
  defp map_list([], _fun), do: []

  defp stringify_value(nil), do: nil
  defp stringify_value(value) when is_boolean(value), do: value
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: inspect(value)

  defp status_string(status) when is_atom(status), do: Atom.to_string(status)
  defp status_string(status), do: to_string(status)

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp generate_id(now) do
    "conf_#{DateTime.to_unix(now, :microsecond)}_#{System.unique_integer([:positive])}"
  end
end
