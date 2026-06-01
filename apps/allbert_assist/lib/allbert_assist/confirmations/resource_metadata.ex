defmodule AllbertAssist.Confirmations.ResourceMetadata do
  @moduledoc """
  Operator-facing resource reference metadata extracted from confirmations/actions.
  """

  alias AllbertAssist.Security.Redactor

  @spec lines(map() | nil) :: [String.t()]
  def lines(confirmation) when is_map(confirmation) do
    confirmation
    |> params_summary()
    |> then(&(browser_summary_lines(&1) ++ resource_lines(&1)))
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

  defp browser_summary_lines(summary) when is_map(summary) do
    if browser_summary?(summary) do
      do_browser_summary_lines(summary)
    else
      []
    end
  end

  defp browser_summary_lines(_summary), do: []

  defp do_browser_summary_lines(summary) do
    [
      browser_line("Browser session", field(summary, "session_id")),
      browser_line("Browser target URL", redacted_url(field(summary, "url"))),
      browser_line("Browser selector", field(summary, "selector")),
      browser_line("Browser label preview", field(summary, "visible_label_preview")),
      browser_line("Browser byte cap", field(summary, "max_bytes")),
      browser_line("Browser screenshot", field(summary, "screenshot_ref"))
    ]
    |> Enum.reject(&blank?/1)
  end

  defp resource_line(ref) when is_map(ref) do
    scope = field(ref, "scope", %{}) || %{}
    scope_value = display_scope_value(ref, scope)
    operation_class = field(ref, "operation_class")

    [
      if(browser_operation?(operation_class), do: "Browser resource", else: "Resource"),
      field(ref, "origin_kind"),
      operation_class,
      field(ref, "access_mode"),
      "#{field(scope, "kind")}:#{scope_value}",
      consumer_text(field(ref, "downstream_consumer"))
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp resource_line(_ref), do: nil

  defp display_scope_value(ref, %{} = scope) do
    metadata = field(ref, "metadata", %{}) || %{}

    case field(scope, "kind") do
      kind when kind in ["exact_url", "url_prefix", :exact_url, :url_prefix] ->
        field(ref, "display_uri") || field(metadata, "display_url") ||
          field(metadata, :display_url) ||
          field(scope, "value")

      _other ->
        field(scope, "value")
    end
  end

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

  defp browser_operation?(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.starts_with?("browser_")

  defp browser_operation?(value) when is_binary(value), do: String.starts_with?(value, "browser_")
  defp browser_operation?(_value), do: false

  defp browser_summary?(summary) do
    Enum.any?(["session_id", "selector", "visible_label_preview", "screenshot_ref"], fn key ->
      field(summary, key) not in [nil, ""]
    end) or
      summary
      |> field("resource_refs", [])
      |> Enum.any?(&(is_map(&1) and browser_operation?(field(&1, "operation_class"))))
  end

  defp browser_line(_label, value) when value in [nil, ""], do: nil
  defp browser_line(label, value), do: "#{label}: #{value}"

  defp redacted_url(nil), do: nil

  defp redacted_url(url) when is_binary(url) do
    Redactor.redact(url)
  end

  defp redacted_url(value), do: value

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
