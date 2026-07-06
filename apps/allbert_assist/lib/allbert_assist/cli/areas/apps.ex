defmodule AllbertAssist.CLI.Areas.Apps do
  @moduledoc """
  Release-safe `apps` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.apps` and `allbert admin apps`:
  `dispatch/2` parses the sub-argv, routes to the same registered actions the
  Mix task used, and returns `{rendered_output, exit_code}` — no `Mix.*` calls,
  so it runs inside the packaged release. `Mix.Tasks.Allbert.Apps` is a thin
  wrapper that prints the output through `Mix.shell/0`.
  """

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.App.Validator
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage """
  Usage:
    allbert admin apps list
    allbert admin apps show APP_ID
    allbert admin apps validate MODULE
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    argv
    |> route(context || default_context())
    |> render()
  end

  defp default_context, do: ContextBuilder.cli_context(surface: "allbert admin apps")

  defp route([], ctx), do: route(["list"], ctx)

  defp route(["list"], ctx) do
    with {:ok, response} <- completed_action("list_apps", %{}, ctx) do
      {:ok, {:list, response}}
    end
  end

  defp route(["show", app_id], ctx) do
    with {:ok, response} <- completed_action("show_app", %{app_id: app_id}, ctx) do
      {:ok, {:show, response.app}}
    end
  end

  defp route(["validate", module_name], _ctx) do
    with {:ok, module} <- resolve_module(module_name),
         :ok <- ensure_app_module(module),
         {:ok, attrs} <- Validator.validate(module, []) do
      {:ok, {:validation, module, attrs}}
    else
      {:error, {:validation_failed, _module}, diagnostics} ->
        {:ok, {:validation_failed, diagnostics}}

      {:error, {_reason, _detail} = reason, diagnostics} ->
        {:error, %{reason: reason, diagnostics: diagnostics}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route(_args, _ctx), do: {:usage, @usage}

  defp render({:ok, {:list, response}}) do
    lines =
      ["Registered apps:"] ++
        Enum.map(response.apps, fn app ->
          "#{app.app_id} #{app.display_name} v#{app.version} actions=#{app.action_count} skills=#{app.skill_path_count} surfaces=#{app.surface_count}"
        end) ++ diagnostic_lines(response.diagnostics)

    Render.ok(lines)
  end

  defp render({:ok, {:show, app}}) do
    Render.ok([
      "App: #{app.app_id}",
      "Display name: #{app.display_name}",
      "Version: #{app.version}",
      "Module: #{inspect(app.module)}",
      "Actions: #{list_value(app.action_names)}",
      "Agents: #{list_value(app.agent_names)}",
      "Skill paths: #{list_value(app.skill_paths)}",
      "Signals: emits=#{app.signal_emit_count} subscribes=#{app.signal_subscribe_count}",
      "Settings schema entries: #{app.settings_schema_count}",
      "Legacy surfaces: #{surface_value(app.surfaces)}",
      "Surface provider surfaces: #{surface_value(app.provider_surfaces)}",
      "Surface catalog entries: #{app.surface_catalog_count}"
      | diagnostic_lines(app.diagnostics)
    ])
  end

  defp render({:ok, {:validation, module, attrs}}) do
    Render.ok([
      "Validation: ok",
      "Module: #{inspect(module)}",
      "App: #{attrs.app_id}",
      "Display name: #{attrs.display_name}",
      "Version: #{attrs.version}",
      "Actions: #{length(attrs.actions)}",
      "Skill paths: #{length(attrs.skill_paths)}",
      "Agents: #{length(attrs.agents)}",
      "Settings schema entries: #{length(attrs.settings_schema)}",
      "Signals: emits=#{length(attrs.signals.emits)} subscribes=#{length(attrs.signals.subscribes)}",
      "Legacy surfaces: #{surface_value(attrs.surfaces)}",
      "Provider surfaces: #{surface_value(attrs.provider_surfaces)}"
    ])
  end

  defp render({:ok, {:validation_failed, diagnostics}}) do
    Render.ok(["Validation: error" | diagnostic_lines(diagnostics)])
  end

  defp render({:error, {:action_failed, response}}), do: Render.error(response.message)
  defp render({:error, reason}), do: Render.error("Apps command failed: #{inspect(reason)}")
  defp render({:usage, usage}), do: Render.usage(usage)

  defp completed_action(action_name, params, ctx) do
    case ActionHelper.completed_action(action_name, params, ctx, error: :response) do
      {:ok, response} -> {:ok, response}
      {:error, response} -> {:error, {:action_failed, response}}
    end
  end

  defp resolve_module(module_name) when is_binary(module_name) do
    normalized = String.trim(module_name)

    candidate_modules()
    |> Enum.find(&(module_matches?(&1, normalized) or app_id_matches?(&1, normalized)))
    |> case do
      nil -> {:error, {:unknown_module, module_name}}
      module -> {:ok, module}
    end
  end

  defp candidate_modules do
    loaded_modules = Enum.map(:code.all_loaded(), fn {module, _path} -> module end)

    app_modules =
      case :application.get_key(:allbert_assist, :modules) do
        {:ok, modules} -> modules
        :undefined -> []
      end

    (loaded_modules ++ app_modules) |> Enum.uniq() |> Enum.filter(&is_atom/1)
  end

  defp module_matches?(module, name) do
    full_name = Atom.to_string(module)
    short_name = String.replace_prefix(full_name, "Elixir.", "")
    name in [full_name, short_name]
  end

  defp app_id_matches?(module, name) do
    safe_app_id?(name) and function_exported?(module, :app_id, 0) and
      module.app_id() |> Atom.to_string() == name
  rescue
    _exception -> false
  end

  defp safe_app_id?(name) when is_binary(name), do: Regex.match?(~r/^[a-z][a-z0-9_]*$/, name)

  defp ensure_app_module(module) do
    cond do
      not Code.ensure_loaded?(module) -> {:error, {:unknown_module, module}}
      app_behaviour?(module) or app_exports?(module) -> :ok
      true -> {:error, {:not_an_allbert_app, module}}
    end
  end

  defp app_behaviour?(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.member?(AllbertAssist.App)
  rescue
    _exception -> false
  end

  defp app_exports?(module) do
    Enum.all?(
      [
        app_id: 0,
        display_name: 0,
        version: 0,
        validate: 1,
        child_spec: 1,
        agents: 0,
        actions: 0,
        signals: 0,
        skill_paths: 0,
        settings_schema: 0,
        surfaces: 0
      ],
      fn {name, arity} -> function_exported?(module, name, arity) end
    )
  end

  defp list_value([]), do: "(none)"
  defp list_value(values), do: Enum.join(values, ", ")

  defp surface_value([]), do: "(none)"

  defp surface_value(surfaces),
    do: surfaces |> Enum.map(&"#{&1.id}:#{&1.path}") |> Enum.join(", ")

  defp diagnostic_lines([]), do: []

  defp diagnostic_lines(diagnostics) do
    ["Diagnostics:"] ++
      Enum.map(diagnostics, fn d ->
        "- #{Map.get(d, :kind, :app_diagnostic)} #{Map.get(d, :message, "App diagnostic.")}"
      end)
  end
end
