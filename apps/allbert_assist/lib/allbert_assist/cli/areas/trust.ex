defmodule AllbertAssist.CLI.Areas.Trust do
  @moduledoc """
  Release-safe `trust` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.security` and
  `allbert admin trust`: `dispatch/2` parses the sub-argv, routes to the same
  registered actions the Mix task used, and returns `{rendered_output,
  exit_code}` — no `Mix.*` calls, so it runs inside the packaged release.
  `Mix.Tasks.Allbert.Security` is a thin wrapper that prints the output through
  `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage """
  Usage:
    mix allbert.security status
    mix allbert.security review --recent [--limit N]
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin trust")

  defp route(["status"], ctx) do
    with {:ok, response} <- completed_action("security_status", %{}, ctx) do
      {:ok, {:status, response.security_status}}
    end
  end

  defp route(["review", "--recent" | opts], ctx) do
    with {:ok, limit} <- parse_limit(opts),
         {:ok, response} <- completed_action("security_review", %{limit: limit}, ctx) do
      {:ok, {:review, response.security_review}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp render({:ok, {:status, status}}) do
    Render.ok(
      [
        "Security Central",
        "Permissions:"
      ] ++
        Enum.map(status.permission_defaults, fn policy ->
          "- #{policy.permission} setting=#{policy.setting_key || "built_in"} configured=#{inspect(policy.configured)} effective=#{policy.effective} source=#{policy.source} capped=#{policy.capped?}"
        end) ++
        ["Safety floors:"] ++
        Enum.map(status.safety_floors, fn floor ->
          "- #{floor.permission}=#{floor.floor}"
        end) ++
        [
          "Secrets: providers=#{status.secret_status.providers} configured=#{status.secret_status.configured} missing=#{status.secret_status.missing}"
        ] ++
        settings_version_lines(status.settings_version_contract) ++
        ["Future boundaries:"] ++
        Enum.map(status.future_boundaries, fn boundary ->
          "- #{boundary.name} #{boundary.milestone} #{boundary.status}"
        end)
    )
  end

  defp render({:ok, {:review, review}}) do
    Render.ok(
      [
        "Security Review",
        "Generated: #{review.generated_at}",
        "Limit: #{review.limit}"
      ] ++
        review_section_lines("Recent confirmations", review.confirmations) ++
        review_section_lines("Recent denials", review.denials) ++
        review_section_lines("Recent imports", review.imports) ++
        review_section_lines("Recent external calls", review.external_calls) ++
        redaction_incident_lines(review.redaction_incidents) ++
        emergency_switch_lines(review.emergency_switches)
    )
  end

  defp render({:usage, usage}), do: Render.usage(usage)

  defp render({:error, {:unknown_review_option, other}}) do
    Render.error("Unknown security review option(s): #{Enum.join(other, " ")}")
  end

  defp render({:error, reason}), do: Render.error("Security command failed: #{inspect(reason)}")

  defp settings_version_lines(report) do
    counts = report.counts

    [
      "Settings versions: status=#{report.status} total=#{report.total_fragments} current=#{counts.current} pending=#{counts.pending} forward=#{counts.forward} invalid=#{counts.invalid}"
    ] ++
      Enum.map(report.diagnostics, fn diagnostic ->
        "- #{diagnostic.fragment_id} #{diagnostic.status}: #{diagnostic.message}"
      end)
  end

  defp review_section_lines(title, []), do: ["#{title}: none"]

  defp review_section_lines(title, items) do
    ["#{title}:"] ++
      Enum.map(items, fn item ->
        "- #{item.id} status=#{item.status} action=#{Map.get(item, :target_action, "unknown")} permission=#{Map.get(item, :target_permission, "unknown")} decision=#{get_in(item, [:security_decision, :decision]) || "unknown"}"
      end)
  end

  defp redaction_incident_lines([]), do: ["Redaction incidents: none"]

  defp redaction_incident_lines(items) do
    ["Redaction incidents:"] ++
      Enum.map(items, fn item ->
        "- #{item.category} id=#{item.id} status=#{item.status} action=#{Map.get(item, :target_action, "unknown")}"
      end)
  end

  defp emergency_switch_lines(switches) do
    ["Emergency switches:"] ++
      Enum.map(switches, fn switch ->
        "- #{switch.key} value=#{inspect(switch.value)} hard_disabled=#{switch.hard_disabled?} boundary=#{switch.boundary}"
      end)
  end

  defp completed_action(action_name, params, ctx) do
    ActionHelper.completed_action(action_name, params, ctx)
  end

  defp parse_limit(["--limit", value | _rest]), do: {:ok, value}
  defp parse_limit([]), do: {:ok, 10}
  defp parse_limit(other), do: {:error, {:unknown_review_option, other}}
end
