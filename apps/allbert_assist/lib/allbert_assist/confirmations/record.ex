defmodule AllbertAssist.Confirmations.Record do
  @moduledoc false

  alias AllbertAssist.Security.Redactor

  @pending_status "pending"
  @statuses ~w(pending approved denied expired cancelled adapter_unavailable)

  @required_string_fields ~w(id status requested_at expires_at)
  @required_map_fields ~w(origin target_action security_decision params_summary)

  @doc "Build a validated pending confirmation record."
  def new(attrs, now, ttl_minutes) when is_map(attrs) and is_integer(ttl_minutes) do
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
      "resolved_at" => DateTime.to_iso8601(now)
    }
    |> drop_nil_values()
    |> Redactor.redact()
  end

  defp target_action(attrs) do
    attrs
    |> value(:target_action, %{})
    |> case do
      value when is_map(value) -> redacted_map(value)
      value -> %{"name" => stringify(value)}
    end
  end

  defp redacted_map(value) when is_map(value) do
    value
    |> stringify_keys()
    |> Redactor.redact()
  end

  defp redacted_map(_value), do: %{}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_map(value) ->
        {to_string(key), stringify_keys(value)}

      {key, value} when is_list(value) ->
        {to_string(key), Enum.map(value, &stringify_list_value/1)}

      {key, value} ->
        {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_list_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_list_value(value), do: stringify_value(value)

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
