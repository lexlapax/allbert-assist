defmodule AllbertAssist.Theme.StatusTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Theme.Status

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home = temp_path("home")
    System.put_env("ALLBERT_HOME", home)
    Paths.ensure_home!()

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    {:ok, home: home}
  end

  test "summary reports disabled override layers by default" do
    summary = Status.summary()

    assert summary.token.status == :not_selected
    assert summary.token.basename == nil
    assert summary.snippets.status == :disabled
    assert summary.snippets.enabled? == false
    assert summary.layout.status == :disabled
    assert summary.layout.enabled? == false
    assert summary.diagnostics == []
  end

  test "summary reports selected local files without storing file contents", %{home: home} do
    theme_path = Path.join([home, "themes", "midnight.yaml"])
    snippet_path = Path.join([home, "themes", "snippets", "compact.css"])
    layout_path = Path.join([home, "workspace", "layout.yaml"])

    File.write!(theme_path, "tokens:\n  allbert-surface-0: \"#101820\"\n")
    File.write!(snippet_path, "#workspace-shell { --allbert-space-2: 0.25rem; }\n")
    File.write!(layout_path, "launcher_order:\n  - output\n  - workspace:settings\n")

    assert {:ok, _setting} = Settings.put("workspace.theme.active", "midnight", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("workspace.theme.snippets_enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("workspace.theme.enabled_snippets", ["compact"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("workspace.layout.override_enabled", true, %{audit?: false})

    summary = Status.summary()

    assert summary.token.status == :present
    assert summary.token.basename == "midnight.yaml"
    assert byte_size(summary.token.fingerprint) == 16
    assert is_integer(summary.token.mtime)

    assert summary.snippets.status == :present

    assert [%{status: :present, basename: "compact.css", fingerprint: fingerprint}] =
             summary.snippets.items

    assert byte_size(fingerprint) == 16

    assert summary.layout.status == :present
    assert summary.layout.basename == "layout.yaml"
    assert byte_size(summary.layout.fingerprint) == 16
    assert summary.diagnostics == []
  end

  test "summary bounds unsafe selections and missing file diagnostics", %{home: home} do
    assert {:ok, _setting} =
             Settings.put("workspace.theme.active", "../secret", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("workspace.theme.snippets_enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("workspace.theme.enabled_snippets", ["../bad"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("workspace.layout.override_enabled", true, %{audit?: false})

    summary = Status.summary()

    assert summary.token.status == :invalid_selection
    assert summary.snippets.status == :unavailable
    assert summary.layout.status == :missing

    assert length(summary.diagnostics) <= 8

    for diagnostic <- summary.diagnostics do
      assert String.length(diagnostic) <= 180
      refute diagnostic =~ home
      refute diagnostic =~ "secret://"
    end
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-theme-status-#{name}-#{System.unique_integer([:positive])}"
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
