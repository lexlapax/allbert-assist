defmodule Mix.Tasks.Allbert.Plugins do
  @moduledoc """
  Inspect registered Allbert plugins.

  ## Usage

      mix allbert.plugins list
      mix allbert.plugins show PLUGIN_ID
      mix allbert.plugins diagnostics
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Inspect registered Allbert plugins"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list"]) do
    with {:ok, response} <- completed_action("list_plugins", %{}) do
      {:ok, {:list, response}}
    end
  end

  defp dispatch(["show", plugin_id]) do
    with {:ok, response} <- completed_action("show_plugin", %{plugin_id: plugin_id}) do
      {:ok, {:show, response.plugin}}
    end
  end

  defp dispatch(["diagnostics"]) do
    with {:ok, response} <- completed_action("list_plugins", %{}) do
      {:ok, {:diagnostics, response.diagnostics}}
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.plugins list
      mix allbert.plugins show PLUGIN_ID
      mix allbert.plugins diagnostics
    """)
  end

  defp print_result({:ok, {:list, response}}) do
    Mix.shell().info("Registered plugins:")

    response.plugins
    |> Enum.each(fn plugin ->
      Mix.shell().info(
        "#{plugin.plugin_id} source=#{plugin.source} kind=#{plugin.kind} status=#{plugin.status} trust=#{plugin.trust_status} #{contributions(plugin)}"
      )
    end)

    print_diagnostics(response.diagnostics)
  end

  defp print_result({:ok, {:show, plugin}}) do
    Mix.shell().info("Plugin: #{plugin.plugin_id}")
    Mix.shell().info("Name: #{plugin.display_name}")
    Mix.shell().info("Version: #{plugin.version}")
    Mix.shell().info("Source: #{plugin.source}")
    Mix.shell().info("Status: #{plugin.status}")
    Mix.shell().info("Trust: #{plugin.trust_status}")
    Mix.shell().info("Module: #{module_value(plugin.module)}")
    Mix.shell().info("Channels: #{list_value(plugin.channels)}")
    Mix.shell().info("Actions: #{list_value(plugin.actions)}")
    Mix.shell().info("Apps: #{list_value(plugin.apps)}")
    Mix.shell().info("Skill paths: #{list_value(plugin.skill_paths)}")
    Mix.shell().info("Settings schema entries: #{plugin.settings_schema_count}")
    Mix.shell().info("Child spec: #{plugin.child_spec?}")
    print_diagnostics(plugin.diagnostics)
  end

  defp print_result({:ok, {:diagnostics, []}}) do
    Mix.shell().info("Plugin diagnostics: none")
  end

  defp print_result({:ok, {:diagnostics, diagnostics}}) do
    Mix.shell().info("Plugin diagnostics:")
    print_diagnostics(diagnostics)
  end

  defp print_result({:error, {:action_failed, response}}) do
    Mix.raise(response.message)
  end

  defp completed_action(action_name, params) do
    case Runner.run(action_name, params, context()) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, {:action_failed, response}}
    end
  end

  defp context, do: %{request: %{channel: :cli, operator_id: "local", user_id: "local"}}

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

  defp print_diagnostics([]), do: :ok

  defp print_diagnostics(diagnostics) do
    Mix.shell().info("Diagnostics:")

    Enum.each(diagnostics, fn diagnostic ->
      Mix.shell().info("- #{diagnostic_kind(diagnostic)} #{diagnostic_message(diagnostic)}")
    end)
  end

  defp diagnostic_kind(diagnostic), do: Map.get(diagnostic, :kind, :plugin_diagnostic)
  defp diagnostic_message(diagnostic), do: Map.get(diagnostic, :message, "Plugin diagnostic.")
end
