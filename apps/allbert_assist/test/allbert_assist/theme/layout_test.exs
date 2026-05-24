defmodule AllbertAssist.Theme.LayoutTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Theme.Layout
  alias AllbertAssist.Workspace.Catalog

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

  test "layout overrides are disabled until the settings gate is enabled", %{home: home} do
    File.write!(
      Path.join([home, "workspace", "layout.yaml"]),
      "default_destination: workspace:settings\n"
    )

    assert %{enabled?: false, status: :disabled, default_destination: "output"} = Layout.current()
    assert Layout.default_destination() == "output"
  end

  test "valid layout data reorders and hides only known hideable destinations", %{home: home} do
    File.write!(
      Path.join([home, "workspace", "layout.yaml"]),
      """
      default_destination: workspace:settings
      launcher_order:
        - workspace:settings
        - output
        - app:stocksage
        - workspace:missing
      hidden_destinations:
        - workspace:jobs
        - output
        - workspace:settings
      panel_pins:
        workspace:settings:
          - stocksage.fixture_panel
          - missing.panel
      active_app: stocksage
      route: /objectives
      """
    )

    assert {:ok, _setting} =
             Settings.put("workspace.layout.override_enabled", true, %{audit?: false})

    context = %{
      registered_apps: [%{app_id: :stocksage, display_name: "StockSage"}],
      panel_surfaces: [panel_surface(%{app_id: :stocksage})]
    }

    layout = Layout.current(context)

    assert layout.status == :partial
    assert layout.default_destination == "workspace:settings"
    assert layout.launcher_order == ["workspace:settings", "output", "app:stocksage"]
    assert layout.hidden_destinations == ["workspace:jobs"]
    assert MapSet.member?(layout.panel_pins["workspace:settings"], "stocksage.fixture_panel")
    assert byte_size(layout.fingerprint) == 16
    assert is_integer(layout.mtime)

    assert Enum.any?(layout.diagnostics, &(&1 =~ "workspace:missing is unknown"))
    assert Enum.any?(layout.diagnostics, &(&1 =~ "output is non-hideable"))
    assert Enum.any?(layout.diagnostics, &(&1 =~ "workspace:settings is non-hideable"))
    assert Enum.any?(layout.diagnostics, &(&1 =~ "active_app ignored"))
    assert Enum.any?(layout.diagnostics, &(&1 =~ "route ignored"))

    destinations =
      layout
      |> Layout.launcher_destinations(Catalog.known_destinations(context))
      |> Enum.map(& &1.id)

    assert Enum.take(destinations, 3) == ["workspace:settings", "output", "app:stocksage"]
    refute "workspace:jobs" in destinations
    assert "output" in destinations
    assert "workspace:settings" in destinations
  end

  test "invalid default destinations and malformed YAML fall back safely", %{home: home} do
    path = Path.join([home, "workspace", "layout.yaml"])

    File.write!(
      path,
      "default_destination: app:allbert\nhidden_destinations:\n  - workspace:jobs\n"
    )

    assert {:ok, _setting} =
             Settings.put("workspace.layout.override_enabled", true, %{audit?: false})

    layout = Layout.current()

    assert layout.status == :partial
    assert layout.default_destination == "output"
    assert Enum.any?(layout.diagnostics, &(&1 =~ "app:allbert"))

    File.write!(path, "launcher_order: [")

    invalid = Layout.current()

    assert invalid.status == :invalid
    assert invalid.default_destination == "output"
    assert invalid.launcher_order == []
  end

  defp panel_surface(attrs) do
    struct!(
      Surface,
      Map.merge(
        %{
          id: :fixture_panel,
          app_id: :allbert,
          label: "Fixture Panel",
          path: "/workspace",
          kind: :panel,
          zone: :canvas_panels,
          status: :available,
          nodes: [
            %Node{
              id: "fixture-panel-root",
              component: :panel,
              props: %{title: "Fixture panel"},
              children: [%Node{id: "fixture-panel-body", component: :text, props: %{body: "ok"}}]
            }
          ],
          fallback_text: "Fixture panel."
        },
        attrs
      )
    )
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-theme-layout-#{name}-#{System.unique_integer([:positive])}"
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
