defmodule AllbertAssistWeb.PageControllerTest do
  use AllbertAssistWeb.ConnCase

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

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

    :ok
  end

  test "GET / renders the M6 brand + marketing landing", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    # Brand + marketing hero (the ADR-accepted thin-landing is retired).
    assert html =~ ~s(class="allbert-landing")
    assert html =~ "A personal assistant runtime that grows with you"
    assert html =~ ~s(src="/images/allbert-mark.svg")
    assert html =~ "Open workspace"
    assert html =~ ~s(id="home-operator-shell")
    assert html =~ ~s(data-workspace-shell="operator")
    assert html =~ ~s(data-active-page="launch")
    assert html =~ ~s(class="workspace-button workspace-button-primary")
    assert html =~ ~s(class="workspace-button workspace-button-secondary")

    # Static SEO / OG metadata (no operator data or secrets).
    assert html =~ ~s(<meta name="description")
    assert html =~ ~s(property="og:title")
    assert html =~ ~s(property="og:image")
    assert html =~ ~s(name="twitter:card")
    assert html =~ ~s(rel="icon" type="image/svg+xml")

    # Stock Phoenix assets retired; no v0.58 accent hexes leaked into markup.
    refute html =~ "Phoenix Framework"
    refute html =~ "/images/logo.svg"
    refute html =~ ~s(data-workspace-renderer="thin-landing")
    refute html =~ "text-slate-"
    refute html =~ "#e8f0f7"
    refute html =~ "#3b5b7a"

    IO.puts("landing-catalog-shell-contract-001 status=pass shell=operator launch=true")
    IO.puts("landing-seo-og-no-data-leak-001 status=pass metadata=static operator_data=false")
  end

  test "root layout applies global design state on non-workspace pages", %{conn: conn} do
    assert {:ok, _setting} = Settings.put("workspace.theme.mode", "dark", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("workspace.accessibility.high_contrast", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("workspace.accessibility.reduce_motion", true, %{audit?: false})

    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(<html lang="en" data-theme="dark">)
    assert html =~ ~s(<body data-high-contrast="true" data-reduce-motion="true">)
    assert html =~ ~s(<main id="main-content" tabindex="-1" class="allbert-page)
    refute html =~ ~s(id="workspace-shell")
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-page-controller-#{name}-#{System.unique_integer([:positive])}"
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
