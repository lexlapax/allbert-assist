defmodule AllbertAssistWeb.DarkModeResolutionTest do
  @moduledoc """
  v0.61 M9 proof: `system` theme mode resolves to the OS `prefers-color-scheme`
  instead of silently falling back to light. The server emits an explicit
  `data-theme="system"` (it cannot know the OS preference), and the CSS resolves that
  marker to the Direction C dark set under OS dark mode; explicit light/dark still win.
  """
  use AllbertAssistWeb.ConnCase

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @moduletag :v061_dark_mode

  @css_path Path.expand("../../assets/css/app.css", __DIR__)

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR", "ALLBERT_SETTINGS_ROOT"]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-dark-mode-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(home)
    System.put_env("ALLBERT_HOME", home)
    Paths.ensure_home!()

    on_exit(fn ->
      File.rm_rf!(home)

      Enum.each(original_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      restore(Paths, original_paths_config)
      restore(Settings, original_settings_config)
    end)

    :ok
  end

  test "system theme mode emits an explicit data-theme=system (not a light fallback)",
       %{conn: conn} do
    assert {:ok, _} = Settings.put("workspace.theme.mode", "system", %{audit?: false})

    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(<html lang="en" data-theme="system">)
    refute html =~ ~s(<html lang="en" data-theme="light">)
  end

  test "explicit dark still wins over the system marker", %{conn: conn} do
    assert {:ok, _} = Settings.put("workspace.theme.mode", "dark", %{audit?: false})

    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(<html lang="en" data-theme="dark">)
  end

  test "the CSS resolves data-theme=system to the Direction C dark set under OS dark" do
    css = File.read!(@css_path)

    assert css =~ "@media (prefers-color-scheme: dark)"

    # v0.61b M3 reconciliation: the accent literal follows the subtle dark set
    # (#a99bf7 → #9d90e2); surface-0 is unchanged by design.
    assert css =~
             ~r/\[data-theme="system"\] \{[^}]*color-scheme: dark;[^}]*--allbert-surface-0: #14121f;[^}]*--allbert-accent: #9d90e2;/,
           "the system marker must resolve to the Direction C dark tokens"

    IO.puts("dark-mode-os-resolution-001 status=pass system=resolves_os_dark fallback=not_light")
  end

  defp restore(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore(module, value), do: Application.put_env(:allbert_assist, module, value)
end
