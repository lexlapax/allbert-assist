defmodule Mix.Tasks.Allbert.Apps do
  @moduledoc """
  Inspect and validate registered Allbert workspace apps.

  ## Usage

      mix allbert.apps list
      mix allbert.apps show APP_ID
      mix allbert.apps validate MODULE
  """

  use Mix.Task

  alias AllbertAssist.Actions.Helper, as: ActionHelper
  alias AllbertAssist.App.Validator
  alias AllbertAssist.Surfaces.ContextBuilder

  @shortdoc "Inspect and validate registered Allbert workspace apps"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list"]) do
    with {:ok, response} <- completed_action("list_apps", %{}) do
      {:ok, {:list, response}}
    end
  end

  defp dispatch(["show", app_id]) do
    with {:ok, response} <- completed_action("show_app", %{app_id: app_id}) do
      {:ok, {:show, response.app}}
    end
  end

  defp dispatch(["validate", module_name]) do
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

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.apps list
      mix allbert.apps show APP_ID
      mix allbert.apps validate MODULE
    """)
  end

  defp print_result({:ok, {:list, response}}) do
    Mix.shell().info("Registered apps:")

    response.apps
    |> Enum.each(fn app ->
      Mix.shell().info(
        "#{app.app_id} #{app.display_name} v#{app.version} actions=#{app.action_count} skills=#{app.skill_path_count} surfaces=#{app.surface_count}"
      )
    end)

    print_diagnostics(response.diagnostics)
  end

  defp print_result({:ok, {:show, app}}) do
    Mix.shell().info("App: #{app.app_id}")
    Mix.shell().info("Display name: #{app.display_name}")
    Mix.shell().info("Version: #{app.version}")
    Mix.shell().info("Module: #{inspect(app.module)}")
    Mix.shell().info("Actions: #{list_value(app.action_names)}")
    Mix.shell().info("Agents: #{list_value(app.agent_names)}")
    Mix.shell().info("Skill paths: #{list_value(app.skill_paths)}")

    Mix.shell().info(
      "Signals: emits=#{app.signal_emit_count} subscribes=#{app.signal_subscribe_count}"
    )

    Mix.shell().info("Settings schema entries: #{app.settings_schema_count}")
    Mix.shell().info("Legacy surfaces: #{surface_value(app.surfaces)}")
    Mix.shell().info("Surface provider surfaces: #{surface_value(app.provider_surfaces)}")
    Mix.shell().info("Surface catalog entries: #{app.surface_catalog_count}")
    print_diagnostics(app.diagnostics)
  end

  defp print_result({:ok, {:validation, module, attrs}}) do
    Mix.shell().info("Validation: ok")
    Mix.shell().info("Module: #{inspect(module)}")
    Mix.shell().info("App: #{attrs.app_id}")
    Mix.shell().info("Display name: #{attrs.display_name}")
    Mix.shell().info("Version: #{attrs.version}")
    Mix.shell().info("Actions: #{length(attrs.actions)}")
    Mix.shell().info("Skill paths: #{length(attrs.skill_paths)}")
    Mix.shell().info("Agents: #{length(attrs.agents)}")
    Mix.shell().info("Settings schema entries: #{length(attrs.settings_schema)}")

    Mix.shell().info(
      "Signals: emits=#{length(attrs.signals.emits)} subscribes=#{length(attrs.signals.subscribes)}"
    )

    Mix.shell().info("Legacy surfaces: #{surface_value(attrs.surfaces)}")
    Mix.shell().info("Provider surfaces: #{surface_value(attrs.provider_surfaces)}")
  end

  defp print_result({:ok, {:validation_failed, diagnostics}}) do
    Mix.shell().info("Validation: error")
    print_diagnostics(diagnostics)
  end

  defp print_result({:error, {:action_failed, response}}) do
    Mix.raise(response.message)
  end

  defp print_result({:error, reason}) do
    Mix.raise("Apps command failed: #{inspect(reason)}")
  end

  defp completed_action(action_name, params) do
    case ActionHelper.completed_action(action_name, params, context(), error: :response) do
      {:ok, response} -> {:ok, response}
      {:error, response} -> {:error, {:action_failed, response}}
    end
  end

  defp context, do: ContextBuilder.cli_context(surface: "mix allbert.apps")

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
    loaded_modules =
      :code.all_loaded()
      |> Enum.map(fn {module, _path} -> module end)

    app_modules =
      case :application.get_key(:allbert_assist, :modules) do
        {:ok, modules} -> modules
        :undefined -> []
      end

    (loaded_modules ++ app_modules)
    |> Enum.uniq()
    |> Enum.filter(&is_atom/1)
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

  defp safe_app_id?(name) when is_binary(name) do
    Regex.match?(~r/^[a-z][a-z0-9_]*$/, name)
  end

  defp ensure_app_module(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:unknown_module, module}}

      app_behaviour?(module) or app_exports?(module) ->
        :ok

      true ->
        {:error, {:not_an_allbert_app, module}}
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

  defp surface_value(surfaces) do
    surfaces
    |> Enum.map(&"#{&1.id}:#{&1.path}")
    |> Enum.join(", ")
  end

  defp print_diagnostics([]), do: :ok

  defp print_diagnostics(diagnostics) do
    Mix.shell().info("Diagnostics:")

    Enum.each(diagnostics, fn diagnostic ->
      Mix.shell().info("- #{diagnostic_kind(diagnostic)} #{diagnostic_message(diagnostic)}")
    end)
  end

  defp diagnostic_kind(diagnostic), do: Map.get(diagnostic, :kind, :app_diagnostic)
  defp diagnostic_message(diagnostic), do: Map.get(diagnostic, :message, "App diagnostic.")
end
