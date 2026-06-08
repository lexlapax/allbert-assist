defmodule AllbertAssist.Runtime.PathsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Paths, as: LegacyPaths
  alias AllbertAssist.Runtime.Paths

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_MEMORY_ROOT",
    "ALLBERT_ARTIFACTS_ROOT",
    "DATABASE_PATH"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, LegacyPaths)
    original_settings_config = Application.get_env(:allbert_assist, AllbertAssist.Settings)
    original_memory_config = Application.get_env(:allbert_assist, AllbertAssist.Memory)
    original_artifacts_config = Application.get_env(:allbert_assist, AllbertAssist.Artifacts)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, LegacyPaths)
    Application.delete_env(:allbert_assist, AllbertAssist.Settings)
    Application.delete_env(:allbert_assist, AllbertAssist.Memory)
    Application.delete_env(:allbert_assist, AllbertAssist.Artifacts)

    on_exit(fn ->
      restore_env(original_env)
      restore_app_env(LegacyPaths, original_paths_config)
      restore_app_env(AllbertAssist.Settings, original_settings_config)
      restore_app_env(AllbertAssist.Memory, original_memory_config)
      restore_app_env(AllbertAssist.Artifacts, original_artifacts_config)
    end)
  end

  test "runtime facade preserves existing Allbert Home precedence" do
    home = temp_path("home")
    alias_home = temp_path("home-dir")

    System.put_env("ALLBERT_HOME", home)
    System.put_env("ALLBERT_HOME_DIR", alias_home)

    assert Paths.home() == home
    assert Paths.home() == LegacyPaths.home()
  end

  test "runtime roots preserve existing path locations" do
    home = temp_path("home")
    System.put_env("ALLBERT_HOME", home)

    assert Paths.roots() == %{
             home: home,
             settings: Path.join(home, "settings"),
             memory: Path.join(home, "memory"),
             memory_deleted: Path.join([home, "memory", "deleted"]),
             artifacts: Path.join(home, "artifacts"),
             confirmations: Path.join(home, "confirmations"),
             execution: Path.join(home, "execution"),
             package_installs: Path.join([home, "execution", "package-installs"]),
             external: Path.join(home, "external"),
             external_cache: Path.join([home, "cache", "external-services"]),
             database: Path.join([home, "db", "allbert.sqlite3"]),
             skills: Path.join(home, "skills"),
             cache: Path.join(home, "cache"),
             online_skill_sources: Path.join([home, "cache", "skills", "_sources"]),
             tmp: Path.join(home, "tmp"),
             workspace: Path.join(home, "workspace"),
             workspace_canvas: Path.join([home, "workspace", "canvas"]),
             workspace_ephemeral: Path.join([home, "workspace", "ephemeral"]),
             workspace_secrets: Path.join([home, "workspace", "secrets"]),
             themes: Path.join(home, "themes"),
             theme_snippets: Path.join([home, "themes", "snippets"]),
             dynamic_plugins: Path.join(home, "dynamic_plugins"),
             dynamic_plugins_drafts: Path.join([home, "dynamic_plugins", "drafts"]),
             dynamic_plugins_integrated: Path.join([home, "dynamic_plugins", "integrated"])
           }

    assert Paths.root(:workspace_canvas) == LegacyPaths.workspace_canvas_root()
    assert Paths.root(:database) == LegacyPaths.db_path()
    assert Paths.root(:themes) == LegacyPaths.themes_root()
    assert Paths.root(:artifacts) == LegacyPaths.artifacts_root()
  end

  test "runtime ensure_home! preserves current directory creation behavior" do
    home = temp_path("home")
    System.put_env("ALLBERT_HOME", home)

    assert Paths.ensure_home!() == home

    for root <- [
          :settings,
          :memory,
          :artifacts,
          :confirmations,
          :execution,
          :package_installs,
          :external,
          :external_cache,
          :skills,
          :cache,
          :online_skill_sources,
          :tmp,
          :workspace,
          :workspace_canvas,
          :workspace_ephemeral,
          :workspace_secrets,
          :themes,
          :theme_snippets,
          :dynamic_plugins,
          :dynamic_plugins_drafts,
          :dynamic_plugins_integrated
        ] do
      assert File.dir?(Paths.root(root))
    end

    assert File.dir?(Path.dirname(Paths.db_path()))

    File.rm_rf!(home)
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-runtime-paths-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
