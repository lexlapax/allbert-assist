defmodule StockSage.Actions do
  @moduledoc false

  alias AllbertAssist.Security.PermissionGate
  alias StockSage.Domain

  def capability(permission) do
    %{
      permission: permission,
      exposure: :agent,
      execution_mode: :local_domain,
      skill_backed?: true,
      confirmation: :not_required,
      app_id: :stocksage
    }
  end

  def authorize(permission, context) do
    PermissionGate.authorize(permission, context)
  end

  def user_id(params, context) do
    params
    |> field(:user_id)
    |> blank_to_nil()
    |> case do
      nil -> context |> field(:user_id) |> blank_to_nil()
      value -> value
    end
    |> case do
      nil -> context |> get_in([:request, :user_id]) |> blank_to_nil()
      value -> value
    end
    |> case do
      nil -> context |> field(:operator_id) |> blank_to_nil()
      value -> value
    end
    |> case do
      nil -> "local"
      value -> Domain.normalize_user_id(value)
    end
  end

  def field(map, key, default \\ nil)

  def field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  def field(_map, _key, default), do: default

  def positive_limit(value, default) do
    Domain.normalize_limit(value, default, 100)
  end

  def offset(value), do: Domain.normalize_offset(value)

  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(value), do: value

  def status_from_decision(permission_decision), do: PermissionGate.response_status(permission_decision)

  def allowed?(permission_decision), do: PermissionGate.allowed?(permission_decision)

  def action(name, status, permission, permission_decision, metadata \\ %{}) do
    %{
      name: name,
      status: status,
      permission: permission,
      permission_decision: permission_decision,
      app_id: :stocksage,
      stocksage: metadata
    }
  end
end
