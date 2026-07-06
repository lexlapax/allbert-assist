defmodule AllbertAssist.CLI.Areas.Plugins do
  @moduledoc """
  Release-safe `plugins` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.plugins`, `mix allbert.dynamic`,
  and `allbert admin plugins`: `dispatch/2` parses the sub-argv, routes to the
  same registered actions the Mix tasks used, and returns
  `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside the
  packaged release. This area owns the union of the plugin-registry subcommands
  (`list`/`show`/`diagnostics`) and the v0.37 dynamic draft/integration
  subcommands (`drafts …`/`integrations …`). `Mix.Tasks.Allbert.Plugins` and
  `Mix.Tasks.Allbert.Dynamic` are thin wrappers that print the output through
  `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.ErrorExtraction
  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage """
  Usage:
    allbert admin plugins list
    allbert admin plugins show PLUGIN_ID
    allbert admin plugins diagnostics
    allbert admin plugins drafts list
    allbert admin plugins drafts show SLUG
    allbert admin plugins drafts request SLUG SUMMARY...
    allbert admin plugins drafts discard SLUG
    allbert admin plugins drafts integrate SLUG
    allbert admin plugins integrations show SLUG [REVISION]
    allbert admin plugins integrations rollback SLUG [REVISION]
    allbert admin plugins integrations disable
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin plugins")

  # --- plugin registry subcommands ---

  defp route(["list"], ctx) do
    with {:ok, response} <- plugins_completed_action("list_plugins", %{}, ctx) do
      {:ok, {:list, response}}
    end
  end

  defp route(["show", plugin_id], ctx) do
    with {:ok, response} <- plugins_completed_action("show_plugin", %{plugin_id: plugin_id}, ctx) do
      {:ok, {:show, response.plugin}}
    end
  end

  defp route(["diagnostics"], ctx) do
    with {:ok, response} <- plugins_completed_action("list_plugins", %{}, ctx) do
      {:ok, {:diagnostics, response.diagnostics}}
    end
  end

  # --- dynamic draft/integration subcommands ---

  defp route(["drafts", "list"], ctx) do
    with {:ok, response} <- dynamic_completed_action("list_dynamic_drafts", %{}, ctx) do
      {:ok, {:drafts, response.drafts}}
    end
  end

  defp route(["drafts", "show", slug], ctx) do
    with {:ok, response} <- dynamic_completed_action("show_dynamic_draft", %{slug: slug}, ctx) do
      {:ok, {:draft, response.draft}}
    end
  end

  defp route(["drafts", "request", slug | summary_parts], ctx) when summary_parts != [] do
    params = %{
      slug: slug,
      summary: Enum.join(summary_parts, " "),
      source: "operator",
      explicit_generation?: true
    }

    with {:ok, response} <- dynamic_completed_action("request_dynamic_draft", params, ctx) do
      {:ok, {:requested, response}}
    end
  end

  defp route(["drafts", "integrate", slug], ctx) do
    case Runner.run("integrate_dynamic_draft", %{slug: slug}, ctx) do
      {:ok, %{status: :completed} = response} -> {:ok, {:integrated, response}}
      {:ok, %{status: :needs_confirmation} = response} -> {:ok, {:confirmation, response}}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp route(["drafts", "discard", slug], ctx) do
    with {:ok, response} <- dynamic_completed_action("discard_dynamic_draft", %{slug: slug}, ctx) do
      {:ok, {:discarded, response}}
    end
  end

  defp route(["integrations", "show", slug], ctx) do
    with {:ok, response} <-
           dynamic_completed_action("show_dynamic_integration", %{slug: slug}, ctx) do
      {:ok, {:integration, response.integration}}
    end
  end

  defp route(["integrations", "show", slug, revision], ctx) do
    with {:ok, response} <-
           dynamic_completed_action(
             "show_dynamic_integration",
             %{slug: slug, revision: revision},
             ctx
           ) do
      {:ok, {:integration, response.integration}}
    end
  end

  defp route(["integrations", "rollback", slug], ctx), do: rollback(slug, nil, ctx)
  defp route(["integrations", "rollback", slug, revision], ctx), do: rollback(slug, revision, ctx)

  defp route(["integrations", "disable"], ctx) do
    with {:ok, response} <- dynamic_completed_action("disable_dynamic_live_loader", %{}, ctx) do
      {:ok, {:disabled, response}}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  # --- plugin registry renders ---

  defp render({:ok, {:list, response}}) do
    Render.ok(
      ["Registered plugins:"] ++
        Enum.map(response.plugins, fn plugin ->
          "#{plugin.plugin_id} source=#{plugin.source} kind=#{plugin.kind} status=#{plugin.status} trust=#{plugin.trust_status} #{contributions(plugin)}"
        end) ++ diagnostic_lines(response.diagnostics)
    )
  end

  defp render({:ok, {:show, plugin}}) do
    Render.ok([
      "Plugin: #{plugin.plugin_id}",
      "Name: #{plugin.display_name}",
      "Version: #{plugin.version}",
      "Source: #{plugin.source}",
      "Status: #{plugin.status}",
      "Trust: #{plugin.trust_status}",
      "Module: #{module_value(plugin.module)}",
      "Channels: #{list_value(plugin.channels)}",
      "Actions: #{list_value(plugin.actions)}",
      "Apps: #{list_value(plugin.apps)}",
      "Skill paths: #{list_value(plugin.skill_paths)}",
      "Settings schema entries: #{plugin.settings_schema_count}",
      "Child spec: #{plugin.child_spec?}"
      | diagnostic_lines(plugin.diagnostics)
    ])
  end

  defp render({:ok, {:diagnostics, []}}), do: Render.ok("Plugin diagnostics: none")

  defp render({:ok, {:diagnostics, diagnostics}}) do
    Render.ok(["Plugin diagnostics:" | diagnostic_lines(diagnostics)])
  end

  # --- dynamic draft/integration renders ---

  defp render({:ok, {:drafts, []}}), do: Render.ok("No dynamic drafts found.")

  defp render({:ok, {:drafts, drafts}}) do
    Render.ok(
      Enum.map(drafts, fn draft ->
        "#{draft.slug} revision=#{draft.revision} tier=#{draft.tier} producer=#{draft.producer}#{pattern_label(draft)} gate=#{draft.gate_status || "not_run"}"
      end)
    )
  end

  defp render({:ok, {:draft, draft}}) do
    Render.ok(
      [
        "Slug: #{draft.slug}",
        "Revision: #{draft.revision}",
        "Tier: #{draft.tier}",
        "Producer: #{draft.producer}"
      ] ++
        pattern_lines(draft) ++
        [
          "Gate: #{draft.gate_status || "not_run"}",
          "Static validation: #{draft.static_validation_status || "not_run"}",
          "Root: #{draft.root}"
        ]
    )
  end

  defp render({:ok, {:integration, integration}}) do
    Render.ok([
      "Slug: #{integration.slug}",
      "Revision: #{integration.revision}",
      "Tier: #{integration.tier}",
      "Root: #{integration.root}"
    ])
  end

  defp render({:ok, {:confirmation, response}}) do
    Render.ok([
      response.message,
      "Approve with:",
      "  mix allbert.confirmations approve #{response.confirmation_id}"
    ])
  end

  defp render({:ok, {:requested, response}}) do
    Render.ok([response.message, "Draft root: #{response.draft.root}"])
  end

  defp render({:ok, {:discarded, response}}), do: Render.ok(response.message)
  defp render({:ok, {:integrated, response}}), do: Render.ok(response.message)
  defp render({:ok, {:rolled_back, response}}), do: Render.ok(response.message)
  defp render({:ok, {:disabled, response}}), do: Render.ok(response.message)

  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, {:action_failed, response}}), do: Render.error(response.message)

  defp render({:error, reason}),
    do: Render.error("Dynamic metadata command failed: #{inspect(reason)}")

  defp plugins_completed_action(action_name, params, ctx) do
    case ActionHelper.completed_action(action_name, params, ctx, error: :response) do
      {:ok, response} -> {:ok, response}
      {:error, response} -> {:error, {:action_failed, response}}
    end
  end

  defp dynamic_completed_action(action_name, params, ctx) do
    ActionHelper.completed_action(action_name, params, ctx)
  end

  defp rollback(slug, revision, ctx) do
    params = if is_nil(revision), do: %{slug: slug}, else: %{slug: slug, revision: revision}

    case Runner.run("rollback_dynamic_integration", params, ctx) do
      {:ok, %{status: :completed} = response} -> {:ok, {:rolled_back, response}}
      {:ok, %{status: :needs_confirmation} = response} -> {:ok, {:confirmation, response}}
      {:ok, response} -> {:error, response_error(response)}
    end
  end

  defp response_error(response), do: ErrorExtraction.from_response(response)

  defp contributions(plugin) do
    [
      "channels=#{plugin.contributions.channels}",
      "skills=#{plugin.contributions.skill_paths}",
      "apps=#{plugin.contributions.apps}",
      "actions=#{plugin.contributions.actions}"
    ]
    |> Enum.join(" ")
  end

  defp module_value(nil), do: "(none)"
  defp module_value(module), do: inspect(module)

  defp list_value([]), do: "(none)"
  defp list_value(values), do: Enum.join(values, ", ")

  defp pattern_lines(draft) do
    if draft.template_pattern_id,
      do: ["Template pattern: #{draft.template_pattern_id}"],
      else: []
  end

  defp pattern_label(%{template_pattern_id: nil}), do: ""
  defp pattern_label(%{template_pattern_id: pattern_id}), do: " pattern=#{pattern_id}"

  defp diagnostic_lines([]), do: []

  defp diagnostic_lines(diagnostics) do
    ["Diagnostics:"] ++
      Enum.map(diagnostics, fn diagnostic ->
        "- #{diagnostic_plugin(diagnostic)}#{diagnostic_kind(diagnostic)} #{diagnostic_message(diagnostic)}"
      end)
  end

  defp diagnostic_plugin(%{plugin_id: plugin_id}) when is_binary(plugin_id), do: "#{plugin_id}: "
  defp diagnostic_plugin(_diagnostic), do: ""

  defp diagnostic_kind(diagnostic), do: Map.get(diagnostic, :kind, :plugin_diagnostic)
  defp diagnostic_message(diagnostic), do: Map.get(diagnostic, :message, "Plugin diagnostic.")
end
