defmodule AllbertAssist.Security.Review do
  @moduledoc """
  Read-only operator review surface for recent security decisions.
  """

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Maps
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings
  alias AllbertAssist.Validation

  @default_limit 10
  @max_limit 50
  @emergency_switches [
    %{
      key: "external_services.enabled",
      default: false,
      boundary: :external_services,
      disables: "confirmed Req-backed external HTTP calls"
    },
    %{
      key: "stocksage.bridge_enabled",
      default: true,
      boundary: :stocksage_bridge,
      disables: "StockSage Python bridge Port creation"
    },
    %{
      key: "plugins.registration_enabled",
      default: true,
      boundary: :plugin_registry,
      disables: "new plugin contribution registration"
    },
    %{
      key: "app_registry.registration_enabled",
      default: true,
      boundary: :app_registry,
      disables: "new app contract registration"
    },
    %{
      key: "workspace.fragment.emission_enabled",
      default: true,
      boundary: :workspace_fragments,
      disables: "workspace fragment emission and receiver persistence"
    }
  ]

  @doc "Return a redacted recent security review."
  @spec recent(map() | keyword()) :: map()
  def recent(opts \\ %{}) do
    limit = opts |> field(:limit, @default_limit) |> normalize_limit()
    confirmations = recent_confirmations(limit)

    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      limit: limit,
      confirmations: confirmations,
      denials: denials(confirmations, limit),
      imports: imports(confirmations, limit),
      external_calls: external_calls(confirmations, limit),
      redaction_incidents: redaction_incidents(confirmations, limit),
      emergency_switches: emergency_switches()
    }
    |> Redactor.redact()
  end

  @doc "Return operator-facing emergency disable switch status."
  @spec emergency_switches() :: [map()]
  def emergency_switches do
    Enum.map(@emergency_switches, fn switch ->
      value = setting(switch.key, switch.default)

      %{
        key: switch.key,
        boundary: switch.boundary,
        value: value,
        hard_disabled?: disabled_value?(value),
        disables: switch.disables
      }
    end)
  end

  defp recent_confirmations(limit) do
    (Confirmations.list(status: :pending) ++ Confirmations.list(status: :resolved))
    |> Enum.map(&confirmation_summary/1)
    |> Enum.sort_by(&(&1.sort_at || ""), :desc)
    |> Enum.take(limit)
    |> Enum.map(&Map.delete(&1, :sort_at))
  end

  defp confirmation_summary(record) do
    %{
      id: Map.get(record, "id"),
      status: Map.get(record, "status"),
      requested_at: Map.get(record, "requested_at"),
      resolved_at: Map.get(record, "resolved_at"),
      target_action: get_in(record, ["target_action", "name"]),
      target_permission: Map.get(record, "target_permission"),
      target_execution_mode: Map.get(record, "target_execution_mode"),
      security_decision: decision_summary(Map.get(record, "security_decision", %{})),
      origin: origin_summary(Map.get(record, "origin", %{})),
      objective_id: Map.get(record, "objective_id"),
      step_id: Map.get(record, "step_id"),
      redaction_applied?: contains_value?(record, "[REDACTED]"),
      sort_at: Map.get(record, "resolved_at") || Map.get(record, "requested_at")
    }
    |> drop_empty()
  end

  defp decision_summary(decision) when is_map(decision) do
    %{
      permission: Map.get(decision, "permission"),
      decision: Map.get(decision, "decision"),
      reason: Map.get(decision, "reason")
    }
    |> drop_empty()
  end

  defp decision_summary(_decision), do: %{}

  defp origin_summary(origin) when is_map(origin) do
    %{
      actor: Map.get(origin, "actor") || Map.get(origin, "user_id"),
      channel: Map.get(origin, "channel"),
      surface: Map.get(origin, "surface")
    }
    |> drop_empty()
  end

  defp origin_summary(_origin), do: %{}

  defp denials(confirmations, limit) do
    confirmations
    |> Enum.filter(fn item ->
      item.status in ["denied", :denied] ||
        get_in(item, [:security_decision, :decision]) in ["denied", :denied]
    end)
    |> Enum.take(limit)
  end

  defp imports(confirmations, limit) do
    confirmations
    |> Enum.filter(fn item ->
      permission = to_string(Map.get(item, :target_permission, ""))
      action = to_string(Map.get(item, :target_action, ""))

      String.contains?(permission, "import") or String.contains?(action, "import")
    end)
    |> Enum.take(limit)
  end

  defp external_calls(confirmations, limit) do
    confirmations
    |> Enum.filter(fn item ->
      permission = to_string(Map.get(item, :target_permission, ""))
      mode = to_string(Map.get(item, :target_execution_mode, ""))

      permission in ["external_network", "stocksage_analyze", "stocksage_evidence_fetch"] or
        mode in ["req_http", "external_market_data"]
    end)
    |> Enum.take(limit)
  end

  defp redaction_incidents(confirmations, limit) do
    confirmations
    |> Enum.filter(&Map.get(&1, :redaction_applied?, false))
    |> Enum.map(fn item ->
      %{
        category: :confirmation_record,
        id: item.id,
        status: item.status,
        target_action: Map.get(item, :target_action)
      }
      |> drop_empty()
    end)
    |> Enum.take(limit)
  end

  defp normalize_limit(value) when is_integer(value),
    do: Validation.clamp_limit(value, 1, @max_limit)

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> normalize_limit(parsed)
      _other -> @default_limit
    end
  end

  defp normalize_limit(_value), do: @default_limit

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  rescue
    _exception -> default
  end

  defp disabled_value?(false), do: true
  defp disabled_value?("false"), do: true
  defp disabled_value?("disabled"), do: true
  defp disabled_value?("denied"), do: true
  defp disabled_value?(_value), do: false

  defp contains_value?(value, needle) when is_binary(value), do: String.contains?(value, needle)

  defp contains_value?(value, needle) when is_map(value) do
    Enum.any?(value, fn {key, val} ->
      contains_value?(key, needle) or contains_value?(val, needle)
    end)
  end

  defp contains_value?(value, needle) when is_list(value) do
    Enum.any?(value, &contains_value?(&1, needle))
  end

  defp contains_value?(_value, _needle), do: false

  defp field(map, key, default) when is_map(map), do: Maps.field_truthy(map, key) || default

  defp field(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp field(_value, _key, default), do: default

  defp drop_empty(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, "", %{}, []] end)
  end
end
