defmodule AllbertAssist.CLI.Areas.Resources do
  @moduledoc """
  Release-safe `resources` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.resources` and
  `allbert admin resources`: `dispatch/2` parses the sub-argv, routes to the
  same registered actions the Mix task used, and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release. `Mix.Tasks.Allbert.Resources` is a thin wrapper that prints
  the output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage """
  Usage:
    allbert admin resources grants list
    allbert admin resources grants show GRANT_ID
    allbert admin resources grants revoke GRANT_ID [--reason REASON...]
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin resources")

  defp route(["grants", "list"], ctx) do
    with {:ok, response} <- completed_action("list_resource_grants", %{}, ctx) do
      {:ok, {:list, response.grants}}
    end
  end

  defp route(["grants", "show", id], ctx) do
    with {:ok, response} <- completed_action("show_resource_grant", %{id: id}, ctx) do
      {:ok, {:show, response.grant}}
    end
  end

  defp route(["grants", "revoke", id | rest], ctx) do
    params = %{id: id} |> maybe_put(:reason, parse_reason(rest))

    with {:ok, response} <- completed_action("revoke_resource_grant", params, ctx) do
      {:ok, {:revoked, response.grant}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp render({:ok, {:list, []}}), do: Render.ok("No remembered resource grants.")

  defp render({:ok, {:list, grants}}) do
    Render.ok(Enum.map(grants, &grant_summary/1))
  end

  defp render({:ok, {:show, grant}}) do
    Render.ok([
      grant_summary(grant),
      "Created: #{grant["created_at"]}",
      "Expires: #{Map.get(grant, "expires_at", "none")}",
      "Revoked: #{Map.get(grant, "revoked_at", "none")}",
      "Reason: #{Map.get(grant, "reason", "none")}",
      "Audit: #{Map.get(grant, "audit_path", "none")}"
    ])
  end

  defp render({:ok, {:revoked, grant}}) do
    Render.ok(["#{grant["id"]} status=revoked", grant_summary(grant)])
  end

  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, reason}), do: Render.error("Resources command failed: #{inspect(reason)}")

  defp grant_summary(grant) do
    scope = Map.get(grant, "scope", %{}) || %{}

    "#{grant["id"]} status=#{grant_status(grant)} operation=#{grant["operation_class"]} access=#{grant["access_mode"]} resource_uri=#{grant["resource_uri"]} scope=#{scope["kind"]}:#{scope["value"]} consumer=#{Map.get(grant, "downstream_consumer", "none")}"
  end

  defp grant_status(%{"revoked_at" => revoked_at}) when revoked_at not in [nil, ""],
    do: "revoked"

  defp grant_status(_grant), do: "active"

  defp completed_action(action_name, params, ctx) do
    ActionHelper.completed_action(action_name, params, ctx)
  end

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

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)
end
