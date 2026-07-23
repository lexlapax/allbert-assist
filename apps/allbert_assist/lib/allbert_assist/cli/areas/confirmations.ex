defmodule AllbertAssist.CLI.Areas.Confirmations do
  @moduledoc """
  Release-safe `confirmations` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.confirmations` and
  `allbert admin confirmations`: `dispatch/2` parses the sub-argv, routes to the
  same `list/show/approve/deny/expire_confirmations` registered actions the Mix
  task used, and returns `{rendered_output, exit_code}` — no `Mix.*` calls, so
  it runs inside the packaged release. `Mix.Tasks.Allbert.Confirmations` is a
  thin wrapper that prints the output through `Mix.shell/0` (raising a
  `Mix.Error` on failure).
  """

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.ExternalRequestMetadata
  alias AllbertAssist.Confirmations.ObjectiveContext
  alias AllbertAssist.Confirmations.OnlineSkillMetadata
  alias AllbertAssist.Confirmations.PackageInstallMetadata
  alias AllbertAssist.Confirmations.ResourceMetadata
  alias AllbertAssist.Confirmations.ShellCommandMetadata
  alias AllbertAssist.Confirmations.SkillScriptMetadata
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage """
  Usage:
    allbert admin confirmations list [--resolved|--all]
    allbert admin confirmations show CONFIRMATION_ID
    allbert admin confirmations approve CONFIRMATION_ID [--reason REASON...] [--remember SCOPE] [--resource-index N|--remember-all] [--grant-expires-at ISO8601]
    allbert admin confirmations deny CONFIRMATION_ID [--reason REASON...]
    allbert admin confirmations expire
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    ctx = context || default_context()

    result =
      try do
        route(argv, ctx)
      catch
        {:confirmations_error, message} -> {:error, {:message, message}}
      end

    render(result)
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin confirmations")

  defp route(["list" | opts], ctx) do
    with {:ok, response} <-
           completed_action("list_confirmations", %{status: list_status(opts)}, ctx) do
      {:ok, {:list, response.confirmations}}
    end
  end

  defp route(["show", id], ctx) do
    with {:ok, response} <- completed_action("show_confirmation", %{id: id}, ctx) do
      {:ok, {:show, response.confirmation}}
    end
  end

  defp route(["approve", id | rest], ctx) do
    params = parse_approve_options(rest, %{id: id})

    with {:ok, response} <- completed_action("approve_confirmation", params, ctx) do
      {:ok, {:resolved, response.confirmation}}
    end
  end

  defp route(["deny", id | rest], ctx) do
    params = %{id: id} |> maybe_put(:reason, parse_reason(rest))

    with {:ok, response} <- completed_action("deny_confirmation", params, ctx) do
      {:ok, {:resolved, response.confirmation}}
    end
  end

  defp route(["expire"], ctx) do
    with {:ok, response} <- completed_action("expire_confirmations", %{}, ctx) do
      {:ok, {:expired, response.confirmations}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp render({:ok, {:list, []}}), do: Render.ok("No confirmations.")

  defp render({:ok, {:list, confirmations}}) do
    Render.ok(Enum.flat_map(confirmations, &list_item_lines/1))
  end

  defp render({:ok, {:show, confirmation}}) do
    Render.ok(
      [
        summary(confirmation),
        "Requested: #{confirmation["requested_at"]}",
        "Expires: #{confirmation["expires_at"]}",
        "Origin: #{origin_text(confirmation)}",
        "Resolver: #{resolver_text(confirmation)}",
        "Trace: #{Map.get(confirmation, "source_trace_id", "none")}"
      ] ++
        common_metadata_lines(confirmation) ++
        approval_command_lines(confirmation) ++
        status_note_lines(confirmation)
    )
  end

  defp render({:ok, {:resolved, confirmation}}) do
    Render.ok(
      [
        "#{confirmation["id"]} status=#{confirmation["status"]}",
        "Resolver: #{resolver_text(confirmation)}"
      ] ++
        common_metadata_lines(confirmation) ++
        target_result_lines(confirmation) ++
        approval_command_lines(confirmation) ++
        status_note_lines(confirmation)
    )
  end

  defp render({:ok, {:expired, confirmations}}) do
    Render.ok("Expired: #{length(confirmations)}")
  end

  defp render({:error, {:message, message}}), do: Render.error(message)
  defp render({:usage, usage}), do: Render.usage(usage)

  defp render({:error, reason}),
    do: Render.error("Confirmations command failed: #{inspect(reason)}")

  defp list_item_lines(confirmation) do
    [summary(confirmation)] ++
      common_metadata_lines(confirmation) ++
      approval_command_lines(confirmation) ++
      status_note_lines(confirmation)
  end

  defp common_metadata_lines(confirmation) do
    ObjectiveContext.lines(confirmation) ++
      ExternalRequestMetadata.lines(confirmation) ++
      OnlineSkillMetadata.lines(confirmation) ++
      PackageInstallMetadata.lines(confirmation) ++
      ResourceMetadata.lines(confirmation) ++
      remembered_grant_lines(confirmation) ++
      ShellCommandMetadata.lines(confirmation) ++
      SkillScriptMetadata.lines(confirmation)
  end

  defp completed_action(action_name, params, ctx) do
    ActionHelper.completed_action(action_name, params, ctx)
  end

  defp list_status(["--resolved"]), do: "resolved"
  defp list_status(["--all"]), do: "all"
  defp list_status([]), do: "pending"
  defp list_status(_opts), do: "pending"

  defp parse_reason(["--reason" | reason_parts]) do
    reason_parts
    |> Enum.join(" ")
    |> String.trim()
    |> case do
      "" -> nil
      reason -> reason
    end
  end

  defp parse_reason([]), do: nil
  defp parse_reason(_rest), do: nil

  defp parse_approve_options([], params), do: params

  defp parse_approve_options(["--reason" | rest], params) do
    {reason_parts, rest} = Enum.split_while(rest, &(not String.starts_with?(&1, "--")))

    reason_parts
    |> Enum.join(" ")
    |> blank_to_nil()
    |> then(&maybe_put(params, :reason, &1))
    |> then(&parse_approve_options(rest, &1))
  end

  defp parse_approve_options(["--remember", scope | rest], params) do
    parse_approve_options(rest, maybe_put(params, :remember_scope, blank_to_nil(scope)))
  end

  defp parse_approve_options(["--resource-index", index | rest], params) do
    parse_approve_options(
      rest,
      Map.put(params, :resource_index, parse_non_negative_integer!(index, "--resource-index"))
    )
  end

  defp parse_approve_options(["--remember-all" | rest], params) do
    parse_approve_options(rest, Map.put(params, :remember_all, true))
  end

  defp parse_approve_options(["--grant-expires-at", expires_at | rest], params) do
    parse_approve_options(rest, maybe_put(params, :expires_at, blank_to_nil(expires_at)))
  end

  defp parse_approve_options([unknown | _rest] = rest, params) do
    if String.starts_with?(unknown, "--") do
      fail!("Unknown approve option: #{unknown}")
    else
      maybe_put(params, :reason, rest |> Enum.join(" ") |> blank_to_nil())
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp summary(confirmation) do
    "#{confirmation["id"]} status=#{confirmation["status"]} target=#{target_name(confirmation)} permission=#{confirmation["target_permission"]} origin=#{origin_text(confirmation)}"
  end

  defp target_name(confirmation) do
    get_in(confirmation, ["target_action", "name"]) || "unknown"
  end

  defp origin_text(confirmation) do
    origin = Map.get(confirmation, "origin", %{})
    "#{Map.get(origin, "actor", "local")}/#{Map.get(origin, "channel", "unknown")}"
  end

  defp resolver_text(confirmation) do
    resolution = Map.get(confirmation, "operator_resolution", %{}) || %{}

    "#{Map.get(resolution, "resolver_actor", "none")}/#{Map.get(resolution, "resolver_channel", "none")}"
  end

  defp status_note_lines(confirmation) do
    case Confirmations.status_note(confirmation) do
      nil -> []
      note -> ["Note: #{note}"]
    end
  end

  defp remembered_grant_lines(confirmation) do
    confirmation
    |> get_in(["operator_resolution", "remembered_grants"])
    |> List.wrap()
    |> Enum.map(fn grant ->
      scope = Map.get(grant, "scope", %{}) || %{}

      "Remembered grant: #{grant["id"]} #{grant["operation_class"]} #{grant["access_mode"]} #{scope["kind"]}:#{scope["value"]}"
    end)
  end

  # Surface a bounded operator summary of the resumed target's result.
  # Stored at `operator_resolution.target_result` (string-keyed JSON because
  # the confirmation record is persisted as JSON). Only emits lines for
  # resolved confirmations whose target ran; pending records and confirmations
  # without a target_result are no-ops.
  defp target_result_lines(confirmation) do
    target_result =
      confirmation
      |> Map.get("operator_resolution", %{})
      |> Kernel.||(%{})
      |> Map.get("target_result", %{})
      |> Kernel.||(%{})

    target_status =
      confirmation
      |> get_in(["operator_resolution", "target_status"])
      |> case do
        nil -> Map.get(target_result, "status")
        value -> value
      end

    target_action_name = get_in(confirmation, ["target_action", "name"])

    if target_result == %{} do
      []
    else
      render_target_result(target_action_name, target_status, target_result)
    end
  end

  defp render_target_result("run_analysis", target_status, target_result) do
    [
      "Target: run_analysis status=#{bounded_string(target_status || "unknown", 40)}#{maybe_kv(target_result, "stub", "stub")}#{maybe_kv(target_result, "engine", "engine")}#{maybe_kv(target_result, "bridge_duration_ms", "bridge_duration_ms")}#{maybe_kv(target_result, "truncated", "truncated")}"
    ] ++
      target_field_line(target_result, "analysis_id", "Analysis id") ++
      target_field_line(target_result, "ticker", "Ticker") ++
      target_field_line(target_result, "analysis_date", "Analysis date") ++
      target_field_line(target_result, "summary", "Summary", 240)
  end

  defp render_target_result("release_cancellation_proof", _target_status, target_result) do
    [render_cancellation_proof(Map.get(target_result, "output_data", %{}))]
  end

  defp render_target_result(target_action_name, target_status, _target_result) do
    # Generic fallback: surface status only (bounded). Anything more would risk
    # leaking domain-specific fields without a vetted formatter; per-target
    # formatters can be added when their operator-visible fields are documented.
    [
      "Target: #{bounded_string(target_action_name || "unknown", 80)} status=#{bounded_string(target_status || "unknown", 40)}"
    ]
  end

  defp render_cancellation_proof(proof) do
    ordered = [
      "status",
      "mode",
      "containment",
      "boundary",
      "timed_out?",
      "target_tree_dead?",
      "sibling_survived?",
      "cleanup_complete?"
    ]

    values =
      Enum.flat_map(ordered, fn key ->
        case Map.fetch(proof, key) do
          {:ok, value} -> ["#{key}=#{proof_value(key, value)}"]
          :error -> []
        end
      end)

    "OV12 " <> Enum.join(values, " ")
  end

  defp proof_value("status", value) when value in [:passed, "passed"], do: "PASS"
  defp proof_value("status", value), do: value |> to_string() |> String.upcase()
  defp proof_value(_key, value), do: bounded_string(value, 80)

  defp maybe_kv(map, key, label) do
    case Map.get(map, key) do
      nil -> ""
      value -> " #{label}=#{bounded_string(value, 80)}"
    end
  end

  defp target_field_line(map, key, label, max \\ 120) do
    case Map.get(map, key) do
      nil -> []
      "" -> []
      value -> ["#{label}: #{bounded_string(value, max)}"]
    end
  end

  defp bounded_string(value, max) when is_integer(max) and max > 0 do
    string = to_string(value)

    if String.length(string) > max do
      String.slice(string, 0, max) <> "..."
    else
      string
    end
  end

  defp approval_command_lines(%{"status" => "pending", "id" => id}) do
    [
      "Details: mix allbert.confirmations show #{id}",
      "Approve: mix allbert.confirmations approve #{id}",
      "Deny: mix allbert.confirmations deny #{id}",
      "Remember scopes: exact, directory, prefix, source, package"
    ]
  end

  defp approval_command_lines(_confirmation), do: []

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp parse_non_negative_integer!(value, option) do
    case Integer.parse(to_string(value)) do
      {integer, ""} when integer >= 0 -> integer
      _other -> fail!("#{option} must be a non-negative integer")
    end
  end

  @spec fail!(String.t()) :: no_return()
  defp fail!(message), do: throw({:confirmations_error, message})
end
