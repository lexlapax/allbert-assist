defmodule AllbertAssist.Theme.TokensTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Theme.Tokens

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

  test "selected token theme renders only presentational allbert variables", %{home: home} do
    File.write!(
      Path.join([home, "themes", "midnight.yaml"]),
      """
      tokens:
        allbert-surface-0: "#101820"
        allbert-text-strong: "#f8fafc"
        allbert-font-scale: 1.05
        allbert-density: "0.95"
        --allbert-radius: "0.25rem"
        color-base-100: "#ffffff"
        workspace-root-grid: "1fr 1fr"
      """
    )

    assert {:ok, _setting} = Settings.put("workspace.theme.active", "midnight", %{audit?: false})

    selected = Tokens.selected()

    assert selected.status == :partial
    assert selected.basename == "midnight.yaml"
    assert selected.declarations["--allbert-surface-0"] == "#101820"
    assert selected.declarations["--allbert-font-scale"] == "1.05"
    assert selected.declarations["--allbert-density"] == "0.95"
    assert selected.declarations["--allbert-radius"] == "0.25rem"
    refute Map.has_key?(selected.declarations, "--color-base-100")
    refute Map.has_key?(selected.declarations, "--workspace-root-grid")
    assert Enum.any?(selected.diagnostics, &(&1 =~ "color-base-100 ignored"))
    assert byte_size(selected.fingerprint) == 16

    css = Tokens.user_css()

    assert css =~ "#workspace-shell"
    assert css =~ "--allbert-surface-0: #101820;"
    assert css =~ "--allbert-font-scale: 1.05;"
    refute css =~ "--color-base-100"
    refute css =~ "workspace-root-grid"
  end

  test "invalid or missing token files fall back without CSS declarations", %{home: home} do
    assert {:ok, _setting} = Settings.put("workspace.theme.active", "missing", %{audit?: false})

    assert %{status: :missing, declarations: declarations, diagnostics: diagnostics} =
             Tokens.selected()

    assert declarations == %{}
    assert Enum.any?(diagnostics, &(&1 =~ "missing"))
    assert Tokens.user_css() =~ "no active token overrides"

    File.write!(Path.join([home, "themes", "broken.yaml"]), "tokens: [")
    assert {:ok, _setting} = Settings.put("workspace.theme.active", "broken", %{audit?: false})

    assert %{status: :invalid, declarations: declarations, diagnostics: diagnostics} =
             Tokens.selected()

    assert declarations == %{}
    assert diagnostics != []
    assert Tokens.user_css() =~ "no active token overrides"
  end

  test "unsafe theme selection never resolves outside Allbert Home" do
    assert {:ok, _setting} = Settings.put("workspace.theme.active", "../secret", %{audit?: false})

    selected = Tokens.selected()

    assert selected.status == :invalid_selection
    assert selected.basename == nil
    assert selected.declarations == %{}
    assert Enum.any?(selected.diagnostics, &(&1 =~ "unsafe theme name"))
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-theme-tokens-#{name}-#{System.unique_integer([:positive])}"
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
