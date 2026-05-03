defmodule AllbertAssist.Confirmations.ResourceMetadata do
  @moduledoc """
  Operator-facing resource reference metadata extracted from confirmations/actions.
  """

  @spec lines(map() | nil) :: [String.t()]
  def lines(confirmation) when is_map(confirmation) do
    confirmation
    |> params_summary()
    |> resource_lines()
  end

  def lines(_confirmation), do: []

  @spec action_lines(map() | nil) :: [String.t()]
  def action_lines(action) when is_map(action) do
    action
    |> action_summary()
    |> resource_lines()
  end

  def action_lines(_action), do: []

  @spec resource_lines(map()) :: [String.t()]
  def resource_lines(summary) when is_map(summary) do
    summary
    |> field("resource_refs", [])
    |> Enum.map(&resource_line/1)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  def resource_lines(_summary), do: []

  defp resource_line(ref) when is_map(ref) do
    scope = field(ref, "scope", %{}) || %{}

    [
      "Resource",
      field(ref, "origin_kind"),
      field(ref, "operation_class"),
      field(ref, "access_mode"),
      "#{field(scope, "kind")}:#{field(scope, "value")}",
      consumer_text(field(ref, "downstream_consumer"))
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp resource_line(_ref), do: nil

  defp params_summary(confirmation), do: Map.get(confirmation, "params_summary", %{}) || %{}

  defp action_summary(action) do
    [
      "command",
      "script",
      "request",
      "package_install",
      "install_plan",
      "online_skill",
      "online_skill_search",
      "online_skill_detail",
      "online_skill_audit",
      "online_skill_import",
      "online_skill_import_request"
    ]
    |> Enum.find_value(%{}, fn key ->
      case field(action, key) do
        value when value in [nil, %{}] -> nil
        value -> value
      end
    end)
  end

  defp consumer_text(nil), do: nil
  defp consumer_text(value), do: "consumer=#{value}"

  defp blank?(value), do: value in [nil, ""]

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, existing_atom(key), default))
  end

  defp field(_map, _key, default), do: default

  defp existing_atom(key) when is_atom(key), do: key

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
