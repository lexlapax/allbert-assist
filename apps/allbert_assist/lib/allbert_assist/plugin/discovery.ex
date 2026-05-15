defmodule AllbertAssist.Plugin.Discovery do
  @moduledoc false

  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Validator
  alias AllbertAssist.Settings

  @shipped_modules %{
    "allbert.telegram" => AllbertAssist.Plugins.Telegram,
    "allbert.email" => AllbertAssist.Plugins.Email,
    "stocksage" => StockSage.Plugin
  }

  @default_settings %{
    "enabled" => [],
    "disabled" => [],
    "scan_paths" => ["./plugins", "<ALLBERT_HOME>/plugins"],
    "trusted_project_roots" => [],
    "load_policy" => "shipped_and_skill_only"
  }

  @type discovered ::
          {:module, module(), keyword()}
          | {:entry, AllbertAssist.Plugin.Entry.t()}
          | {:diagnostic, String.t(), [map()]}

  @spec discover(keyword()) :: [discovered()]
  def discover(opts \\ []) do
    settings = Keyword.get(opts, :settings, read_settings())
    project_root = Keyword.get(opts, :project_root, default_project_root()) |> Path.expand()

    settings
    |> scan_paths(project_root)
    |> Enum.flat_map(&discover_root(&1, settings, project_root))
    |> Enum.reject(&disabled?(&1, settings))
  end

  @spec shipped_modules() :: %{String.t() => module()}
  def shipped_modules, do: @shipped_modules

  defp read_settings do
    Map.new(@default_settings, fn {key, default} ->
      case Settings.get("plugins.#{key}") do
        {:ok, value} -> {key, value}
        _error -> {key, default}
      end
    end)
  end

  defp scan_paths(settings, project_root) do
    settings
    |> Map.get("scan_paths", @default_settings["scan_paths"])
    |> Enum.map(&expand_scan_path(&1, project_root))
    |> Enum.uniq()
  end

  defp expand_scan_path("<ALLBERT_HOME>/plugins", _project_root),
    do: Path.join(Paths.home(), "plugins")

  defp expand_scan_path(path, project_root) when is_binary(path) do
    path
    |> String.replace("<ALLBERT_HOME>", Paths.home())
    |> Path.expand(project_root)
  end

  defp discover_root(root_path, settings, project_root) do
    cond do
      settings["load_policy"] == "shipped_only" and not shipped_root?(root_path, project_root) ->
        []

      not File.dir?(root_path) ->
        [
          {:diagnostic, root_path,
           [
             Validator.diagnostic(
               :info,
               :plugin_scan_path_missing,
               "Plugin scan path is missing.",
               path: root_path
             )
           ]}
        ]

      true ->
        root_path
        |> File.ls!()
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.map(&Path.join(root_path, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort()
        |> Enum.flat_map(&discover_plugin_folder(&1, settings, project_root))
    end
  end

  defp discover_plugin_folder(folder, settings, project_root) do
    manifest_path = Path.join(folder, "allbert_plugin.json")

    if File.regular?(manifest_path) do
      discover_manifest(manifest_path, folder, source_for(folder, project_root), settings)
    else
      [
        {:diagnostic, folder,
         [
           Validator.diagnostic(
             :debug,
             :plugin_manifest_missing,
             "Plugin folder has no manifest.",
             path: folder
           )
         ]}
      ]
    end
  end

  defp discover_manifest(manifest_path, folder, source, settings) do
    with {:ok, body} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(body) do
      case shipped_module(manifest, source) do
        {:ok, module} ->
          [{:module, module, [source: :shipped, root_path: folder, manifest_path: manifest_path]}]

        :not_shipped ->
          discover_folder_manifest(manifest, source, settings, folder, manifest_path)

        {:error, diagnostics} ->
          [{:diagnostic, manifest_key(manifest, folder), diagnostics}]
      end
    else
      {:error, %Jason.DecodeError{} = error} ->
        [
          {:diagnostic, folder,
           [
             Validator.diagnostic(:error, :invalid_json, "Invalid plugin manifest JSON.",
               error: Exception.message(error)
             )
           ]}
        ]

      {:error, reason} ->
        [
          {:diagnostic, folder,
           [
             Validator.diagnostic(
               :error,
               :manifest_read_failed,
               "Could not read plugin manifest.",
               reason: reason
             )
           ]}
        ]
    end
  end

  defp discover_folder_manifest(manifest, source, settings, folder, manifest_path) do
    enabled = Map.get(settings, "enabled", [])
    plugin_id = Map.get(manifest, "plugin_id")

    opts = [
      source: source,
      root_path: folder,
      manifest_path: manifest_path,
      trust_status: trust_status(source, settings, folder)
    ]

    if source in [:project, :home] and plugin_id not in enabled do
      [{:diagnostic, plugin_id || folder, [disabled_diagnostic(plugin_id || folder)]}]
    else
      case Validator.normalize_manifest(manifest, opts) do
        {:ok, entry} -> [{:entry, entry}]
        {:error, _reason, diagnostics} -> [{:diagnostic, plugin_id || folder, diagnostics}]
      end
    end
  end

  defp shipped_module(%{"plugin_id" => plugin_id, "module" => module_name}, :shipped) do
    with {:ok, module} <- Map.fetch(@shipped_modules, plugin_id),
         true <- module_name == String.replace_prefix(Atom.to_string(module), "Elixir.", "") do
      {:ok, module}
    else
      :error ->
        {:error,
         [
           Validator.diagnostic(
             :error,
             :shipped_plugin_not_allowlisted,
             "Shipped plugin id is not allowlisted.",
             plugin_id: plugin_id
           )
         ]}

      false ->
        {:error,
         [
           Validator.diagnostic(
             :error,
             :shipped_plugin_module_mismatch,
             "Shipped plugin module does not match allowlist.",
             plugin_id: plugin_id,
             module: module_name
           )
         ]}
    end
  end

  defp shipped_module(_manifest, _source), do: :not_shipped

  defp disabled?({:module, module, _opts}, settings) do
    module.plugin_id() in Map.get(settings, "disabled", [])
  end

  defp disabled?({:entry, entry}, settings),
    do: entry.plugin_id in Map.get(settings, "disabled", [])

  defp disabled?({:diagnostic, _key, _diagnostics}, _settings), do: false

  defp trust_status(:shipped, _settings, _folder), do: :trusted
  defp trust_status(:home, _settings, _folder), do: :pending

  defp trust_status(:project, settings, folder) do
    trusted_roots = Enum.map(Map.get(settings, "trusted_project_roots", []), &Path.expand/1)
    folder = Path.expand(folder)

    if Enum.any?(trusted_roots, &(folder == &1 or String.starts_with?(folder, &1 <> "/"))) do
      :trusted
    else
      :pending
    end
  end

  defp source_for(folder, project_root) do
    cond do
      Path.dirname(folder) == Path.join(project_root, "plugins") and
          Path.basename(folder) in Map.keys(@shipped_modules) ->
        :shipped

      String.starts_with?(Path.expand(folder), Path.expand(project_root) <> "/") ->
        :project

      true ->
        :home
    end
  end

  defp shipped_root?(root_path, project_root),
    do: Path.expand(root_path) == Path.join(project_root, "plugins")

  defp default_project_root do
    File.cwd!()
    |> Path.expand()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.find(File.cwd!(), fn path ->
      File.dir?(Path.join(path, "plugins")) or Path.dirname(path) == path
    end)
  end

  defp manifest_key(%{"plugin_id" => plugin_id}, _folder) when is_binary(plugin_id), do: plugin_id
  defp manifest_key(_manifest, folder), do: folder

  defp disabled_diagnostic(plugin_id) do
    Validator.diagnostic(:info, :plugin_not_enabled, "Optional plugin is not enabled.",
      plugin_id: plugin_id
    )
  end
end
