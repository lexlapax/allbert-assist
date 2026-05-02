defmodule AllbertAssist.PathsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Memory
  alias AllbertAssist.Paths

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_MEMORY_ROOT",
    "DATABASE_PATH"
  ]

  setup do
    original_env =
      Map.new(@env_vars, fn key ->
        {key, System.get_env(key)}
      end)

    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, AllbertAssist.Settings)
    original_memory_config = Application.get_env(:allbert_assist, Memory)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, AllbertAssist.Settings)
    Application.delete_env(:allbert_assist, Memory)

    on_exit(fn ->
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(AllbertAssist.Settings, original_settings_config)
      restore_app_env(Memory, original_memory_config)
    end)
  end

  test "home defaults to ~/.allbert without creating it" do
    assert Paths.home() == Path.expand("~/.allbert")
  end

  test "ALLBERT_HOME takes precedence over ALLBERT_HOME_DIR" do
    home = temp_path("home")
    alias_home = temp_path("home-dir")

    System.put_env("ALLBERT_HOME", home)
    System.put_env("ALLBERT_HOME_DIR", alias_home)

    assert Paths.home() == home
  end

  test "ALLBERT_HOME_DIR is accepted as a compatibility alias" do
    home = temp_path("home-dir")

    System.put_env("ALLBERT_HOME_DIR", home)

    assert Paths.home() == home
  end

  test "application config can override Allbert Home for tests" do
    home = temp_path("configured-home")

    System.put_env("ALLBERT_HOME", temp_path("env-home"))
    Application.put_env(:allbert_assist, Paths, home: home)

    assert Paths.home() == home
  end

  test "derived roots use Allbert Home by default" do
    home = temp_path("home")

    System.put_env("ALLBERT_HOME", home)

    assert Paths.settings_root() == Path.join(home, "settings")
    assert Paths.confirmations_root() == Path.join(home, "confirmations")
    assert Paths.memory_root() == Path.join(home, "memory")
    assert Paths.db_path() == Path.join([home, "db", "allbert.sqlite3"])
    assert Paths.skills_root() == Path.join(home, "skills")
    assert Paths.cache_root() == Path.join(home, "cache")
    assert Paths.tmp_root() == Path.join(home, "tmp")
  end

  test "specific root overrides take precedence over derived home paths" do
    home = temp_path("home")
    settings_root = temp_path("settings-root")
    memory_root = temp_path("memory-root")
    database_path = Path.join(temp_path("db-root"), "custom.sqlite3")

    System.put_env("ALLBERT_HOME", home)
    System.put_env("ALLBERT_SETTINGS_ROOT", settings_root)
    System.put_env("ALLBERT_MEMORY_ROOT", memory_root)
    System.put_env("DATABASE_PATH", database_path)

    assert Paths.settings_root() == settings_root
    assert Paths.memory_root() == memory_root
    assert Paths.db_path() == database_path
  end

  test "application root overrides take precedence over env root overrides" do
    settings_root = temp_path("configured-settings")
    memory_root = temp_path("configured-memory")

    System.put_env("ALLBERT_SETTINGS_ROOT", temp_path("env-settings"))
    System.put_env("ALLBERT_MEMORY_ROOT", temp_path("env-memory"))

    Application.put_env(:allbert_assist, AllbertAssist.Settings, root: settings_root)
    Application.put_env(:allbert_assist, Memory, root: memory_root)

    assert Paths.settings_root() == settings_root
    assert Paths.memory_root() == memory_root
  end

  test "ensure_home! creates the expected directory layout" do
    home = temp_path("home")

    System.put_env("ALLBERT_HOME", home)

    assert Paths.ensure_home!() == home

    for path <- [
          home,
          Path.join(home, "settings"),
          Path.join([home, "settings", "audit"]),
          Path.join(home, "confirmations"),
          Path.join([home, "confirmations", "pending"]),
          Path.join([home, "confirmations", "resolved"]),
          Path.join([home, "confirmations", "audit"]),
          Path.join(home, "memory"),
          Path.join([home, "memory", "notes"]),
          Path.join([home, "memory", "preferences"]),
          Path.join([home, "memory", "traces"]),
          Path.join([home, "memory", "skills"]),
          Path.join(home, "db"),
          Path.join(home, "skills"),
          Path.join(home, "cache"),
          Path.join([home, "cache", "skills"]),
          Path.join(home, "tmp")
        ] do
      assert File.dir?(path)
    end

    File.rm_rf!(home)
  end

  test "memory root derives from Allbert Home when no specific override exists" do
    home = temp_path("home")

    System.put_env("ALLBERT_HOME", home)

    assert Memory.root() == Path.join(home, "memory")
  end

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "allbert-paths-#{name}-#{System.unique_integer([:positive])}")
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
