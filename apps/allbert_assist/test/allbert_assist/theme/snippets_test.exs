defmodule AllbertAssist.Theme.SnippetsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Theme.Snippets

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

  test "selected snippets are disabled until the settings gate is enabled", %{home: home} do
    File.write!(Path.join([home, "themes", "snippets", "compact.css"]), safe_css())

    assert {:ok, _setting} =
             Settings.put("workspace.theme.enabled_snippets", ["compact"], %{audit?: false})

    assert %{enabled?: false, css: "", items: [], status: :disabled} = Snippets.selected()

    assert {:ok, _setting} =
             Settings.put("workspace.theme.snippets_enabled", true, %{audit?: false})

    selected = Snippets.selected()

    assert selected.status == :present
    assert selected.css =~ "#workspace-shell .workspace-chat-pane"

    assert [%{basename: "compact.css", status: :present, fingerprint: fingerprint}] =
             selected.items

    assert byte_size(fingerprint) == 16
  end

  test "sanitizer removes imports urls image sets and font sources" do
    unsafe = """
    @import "https://example.com/theme.css";
    @font-face { font-family: Remote; src: url("https://example.com/font.woff2"); }
    #workspace-shell {
      background-image: image-set(url("https://example.com/a.png") 1x);
      color: #111827;
    }
    """

    sanitized = Snippets.sanitize(unsafe)

    assert sanitized.status == :sanitized
    assert sanitized.css =~ "color: #111827"
    refute sanitized.css =~ "@import"
    refute sanitized.css =~ "@font-face"
    refute sanitized.css =~ "url("
    refute sanitized.css =~ "image-set("
    assert Enum.any?(sanitized.diagnostics, &(&1 =~ "@import"))
    assert Enum.any?(sanitized.diagnostics, &(&1 =~ "url()"))
    assert Enum.all?(sanitized.diagnostics, &(not String.contains?(&1, "https://example.com")))
  end

  test "entirely unsafe snippets serve empty CSS", %{home: home} do
    File.write!(
      Path.join([home, "themes", "snippets", "unsafe.css"]),
      ~s(@import "https://example.com/theme.css";\n)
    )

    assert {:ok, _setting} =
             Settings.put("workspace.theme.snippets_enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("workspace.theme.enabled_snippets", ["unsafe"], %{audit?: false})

    selected = Snippets.selected()

    assert selected.status == :empty
    assert selected.css == ""
    assert [%{status: :empty}] = selected.items
    assert selected.diagnostics != []
  end

  test "path traversal and non-css selections are rejected" do
    assert {:ok, _setting} =
             Settings.put("workspace.theme.snippets_enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("workspace.theme.enabled_snippets", ["../secret", "notes.txt"], %{
               audit?: false
             })

    selected = Snippets.selected()

    assert selected.status == :unavailable
    assert Enum.all?(selected.items, &(&1.status == :invalid_selection))
    assert Enum.any?(selected.diagnostics, &(&1 =~ "unsafe snippet name"))
    assert Enum.any?(selected.diagnostics, &(&1 =~ "snippet file must be .css"))
  end

  test "single snippet route helper requires both gate and enabled basename", %{home: home} do
    File.write!(Path.join([home, "themes", "snippets", "compact.css"]), safe_css())

    assert Snippets.single_css("compact").status == :disabled

    assert {:ok, _setting} =
             Settings.put("workspace.theme.snippets_enabled", true, %{audit?: false})

    assert Snippets.single_css("compact").status == :not_enabled

    assert {:ok, _setting} =
             Settings.put("workspace.theme.enabled_snippets", ["compact"], %{audit?: false})

    assert Snippets.single_css("compact").status == :present
  end

  defp safe_css do
    """
    #workspace-shell .workspace-chat-pane {
      font-size: 0.95rem;
    }
    """
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-theme-snippets-#{name}-#{System.unique_integer([:positive])}"
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
