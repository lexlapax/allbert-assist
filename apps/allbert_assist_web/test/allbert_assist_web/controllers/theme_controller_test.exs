defmodule AllbertAssistWeb.ThemeControllerTest do
  use AllbertAssistWeb.ConnCase

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Theme.Version

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

  test "GET /theme/user.css serves selected token CSS", %{conn: conn, home: home} do
    File.write!(
      Path.join([home, "themes", "midnight.yaml"]),
      """
      tokens:
        allbert-surface-0: "#101820"
        allbert-accent: "#7cc7d8"
        color-base-100: "#ffffff"
      """
    )

    assert {:ok, _setting} = Settings.put("workspace.theme.active", "midnight", %{audit?: false})

    conn = get(conn, ~p"/theme/user.css")
    css = response(conn, 200)

    assert get_resp_header(conn, "content-type") == ["text/css; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["private, max-age=0, must-revalidate"]
    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ ~r/^"[0-9a-f]{16}"$/
    assert css =~ "#workspace-shell"
    assert css =~ "--allbert-surface-0: #101820;"
    assert css =~ "--allbert-accent: #7cc7d8;"
    refute css =~ "--color-base-100"

    not_modified =
      conn
      |> recycle()
      |> put_req_header("if-none-match", etag)
      |> get(~p"/theme/user.css")

    assert response(not_modified, 304) == ""
  end

  test "GET /theme/user.css falls back for missing or invalid themes", %{conn: conn, home: home} do
    assert {:ok, _setting} = Settings.put("workspace.theme.active", "missing", %{audit?: false})

    conn = get(conn, ~p"/theme/user.css")
    assert response(conn, 200) =~ "no active token overrides"

    File.write!(Path.join([home, "themes", "broken.yaml"]), "tokens: [")
    assert {:ok, _setting} = Settings.put("workspace.theme.active", "broken", %{audit?: false})

    conn = conn |> recycle() |> get(~p"/theme/user.css")
    assert response(conn, 200) =~ "no active token overrides"
  end

  test "stylesheet version changes when selected token file changes", %{home: home} do
    path = Path.join([home, "themes", "midnight.yaml"])

    File.write!(path, "tokens:\n  allbert-surface-0: \"#101820\"\n")
    assert {:ok, _setting} = Settings.put("workspace.theme.active", "midnight", %{audit?: false})

    first_version = Version.stylesheet_version()

    File.write!(path, "tokens:\n  allbert-surface-0: \"#17212b\"\n")

    assert Version.stylesheet_version() != first_version
  end

  test "root layout links token stylesheet after app.css", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(/assets/css/app.css?)
    assert html =~ ~s(/theme/user.css?)
    refute html =~ "<script>"
    assert :binary.match(html, "/assets/css/app.css") < :binary.match(html, "/theme/user.css")
  end

  test "workspace and theme responses carry CSP headers", %{conn: conn} do
    workspace = get(conn, ~p"/workspace")
    assert [workspace_csp] = get_resp_header(workspace, "content-security-policy")
    assert workspace_csp =~ "default-src 'self'"
    assert workspace_csp =~ "style-src 'self'"
    assert workspace_csp =~ "connect-src 'self' ws: wss:"
    assert workspace_csp =~ "script-src 'self'"
    refute workspace_csp =~ "unsafe-inline"

    theme = conn |> recycle() |> get(~p"/theme/user.css")
    assert [theme_csp] = get_resp_header(theme, "content-security-policy")
    assert theme_csp =~ "default-src 'none'"
    assert theme_csp =~ "script-src 'none'"
    assert theme_csp =~ "style-src 'self'"
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-theme-controller-#{name}-#{System.unique_integer([:positive])}"
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
