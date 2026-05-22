defmodule StockSageWeb.LiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.{App, Plugin, Session, Settings}

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    root = Path.join(System.tmp_dir!(), "stocksage-live-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    ensure_stocksage_registered()
    _ = Session.clear_active_app("local", "web-local")

    on_exit(fn ->
      _ = Session.clear_active_app("local", "web-local")
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "StockSage routes mount and set the active app", %{conn: conn} do
    for {path, root_id} <- [
          {~p"/stocksage", "#stocksage-workspace"},
          {~p"/stocksage/analyses", "#stocksage-analyses"},
          {~p"/stocksage/analyses/ana_test", "#stocksage-analyses"},
          {~p"/stocksage/queue", "#stocksage-queue"},
          {~p"/stocksage/trends", "#stocksage-trends"}
        ] do
      {:ok, view, html} = live(conn, path)

      assert has_element?(view, root_id)
      assert html =~ ~s(data-active-app="stocksage")
    end

    assert {:ok, %{active_app: :stocksage}} = Session.get("local", "web-local")
  end

  test "route surfaces agree with the provider metadata" do
    assert {:ok, attrs} = App.Validator.validate(StockSage.App)

    assert Enum.map(attrs.provider_surfaces, & &1.path) == [
             ~p"/stocksage",
             ~p"/stocksage/analyses",
             ~p"/stocksage/queue",
             ~p"/stocksage/trends"
           ]

    assert Enum.map(attrs.provider_surfaces, & &1.metadata.live_view) == [
             "StockSageWeb.WorkspaceLive",
             "StockSageWeb.AnalysisLive",
             "StockSageWeb.QueueLive",
             "StockSageWeb.TrendsLive"
           ]
  end

  test "disabled web setting leaves routes mounted with bounded disabled state", %{conn: conn} do
    assert {:ok, _setting} = Settings.put("stocksage.web.enabled", false, %{audit?: false})

    {:ok, view, html} = live(conn, ~p"/stocksage")

    assert has_element?(view, "#stocksage-disabled")
    assert html =~ "StockSage web surfaces are disabled"
    assert {:ok, %{active_app: :stocksage}} = Session.get("local", "web-local")
  end

  test "analysis detail uses StockSage-owned card renderers", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/stocksage/analyses/ana_m3_renderer")

    assert has_element?(view, "#stocksage-analysis-surface-nodes")
    assert html =~ ~s(data-stocksage-component="analysis_card")
    assert html =~ "Analysis ana_m3_renderer"
    refute html =~ "v0.26 stub"
  end

  defp ensure_stocksage_registered do
    plugin_registered? = match?({:ok, _entry}, Plugin.Registry.lookup("stocksage"))

    unless plugin_registered? do
      assert Plugin.Registry.register_module(StockSage.Plugin) in [
               {:ok, "stocksage"},
               {:error, {:plugin_id_taken, "stocksage"}}
             ]
    end

    unless App.Registry.known_app_id?(:stocksage) do
      assert {:ok, :stocksage} = App.Registry.register(StockSage.App)
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
