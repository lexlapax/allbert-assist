defmodule Mix.Tasks.Allbert.ValidateApp do
  @moduledoc """
  Validate a compiled Allbert app module against the app/surface contract.

  ## Usage

      mix allbert.validate_app AllbertAssist.App.CoreApp
  """

  use Mix.Task

  alias AllbertAssist.App.Validator

  @shortdoc "Validate a compiled Allbert app module"

  @impl true
  def run([module_name]) do
    Mix.Task.run("app.start")

    with {:ok, module} <- resolve_module(module_name),
         {:ok, attrs} <- Validator.validate(module, []) do
      print_success(attrs)
    else
      {:error, reason, diagnostics} ->
        print_failure(diagnostics)
        Mix.raise("App validation failed: #{inspect(reason)}")

      {:error, reason} ->
        Mix.raise("App validation failed: #{inspect(reason)}")
    end
  end

  def run(_args) do
    Mix.raise("Usage: mix allbert.validate_app MODULE")
  end

  defp resolve_module(module_name) when is_binary(module_name) do
    normalized = String.trim(module_name)

    candidate_modules()
    |> Enum.find(&module_matches?(&1, normalized))
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

  defp print_success(attrs) do
    Mix.shell().info("Validation: ok")
    Mix.shell().info("app_id: #{attrs.app_id}")
    Mix.shell().info("display_name: #{attrs.display_name}")
    Mix.shell().info("version: #{attrs.version}")
    Mix.shell().info("actions: #{length(attrs.actions)}")
    Mix.shell().info("skills: #{length(attrs.skill_paths)}")
    Mix.shell().info("agents: #{length(attrs.agents)}")
    Mix.shell().info("settings_schema: #{length(attrs.settings_schema)}")
    Mix.shell().info("memory_namespace: #{memory_namespace_value(attrs.memory_namespace)}")

    Mix.shell().info(
      "signals: emits=#{length(attrs.signals.emits)} subscribes=#{length(attrs.signals.subscribes)}"
    )

    Mix.shell().info("legacy_surfaces: #{surface_value(attrs.surfaces)}")
    Mix.shell().info("provider_surfaces: #{surface_value(attrs.provider_surfaces)}")
  end

  defp print_failure(diagnostics) do
    Mix.shell().info("Validation: error")

    Enum.each(diagnostics, fn diagnostic ->
      Mix.shell().info(
        "- #{Map.get(diagnostic, :kind, :invalid_app)} #{Map.get(diagnostic, :message, "Invalid app.")}"
      )
    end)
  end

  defp surface_value([]), do: "(none)"

  defp surface_value(surfaces) do
    surfaces
    |> Enum.map(&"#{inspect(&1.id)}:#{&1.path}")
    |> Enum.join(", ")
  end

  defp memory_namespace_value(nil), do: "(none)"

  defp memory_namespace_value(namespace) do
    "#{inspect(namespace.namespace)} writable=#{namespace.writable}"
  end
end
