defmodule AllbertAssistWeb.Workspace.AccessibilityTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.{Confirmations, Paths, Runtime, Session, Settings}

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @runtime_async_timeout 60_000

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-workspace-a11y-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    runner = fn _signal, request ->
      {:ok, %{message: "Runtime LiveView response: #{request.text}", status: :completed}}
    end

    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)
    _ = Session.clear_active_app("local", "web-local")

    on_exit(fn ->
      _ = Session.clear_active_app("local", "web-local")
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)
  end

  test "workspace shell renders named landmarks and controls", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/workspace")

    assert has_element?(view, "#skip-to-content[href='#main-content']")
    assert has_element?(view, "main#main-content[tabindex='-1']")
    refute html =~ "Phoenix Framework"
    refute html =~ "Website"
    assert html =~ "GitHub"
    refute html =~ "Get Started"
    assert has_element?(view, "#allbert-appbar")
    assert has_element?(view, "#workspace-thread-switcher-toggle[aria-haspopup='menu']")
    assert has_element?(view, "#workspace-context-indicator[data-active-app='allbert']")
    assert has_element?(view, "#workspace-objective-count-chip")
    assert has_element?(view, "#workspace-tile-count-chip")
    assert has_element?(view, "#workspace-shell[role='region']")
    assert has_element?(view, "#workspace-theme-toggle[aria-label]")
    assert has_element?(view, "#workspace-overflow-menu[aria-label='Workspace menu']")
    assert has_element?(view, "#workspace-split-resizer[role='separator'][tabindex='0']")
    assert has_element?(view, "#workspace-split-resizer[aria-valuemin='35'][aria-valuemax='70']")
    assert has_element?(view, "#workspace-canvas-cap-chip")
    assert has_element?(view, "label#agent-prompt-label[for='agent-prompt']")
    assert has_element?(view, "#agent-prompt[aria-labelledby='agent-prompt-label']")
    assert has_element?(view, "#agent-form[aria-busy='false']")
    refute html =~ "Workspace shell"
    refute html =~ "Prompt composer"

    assert_all_buttons_named(html)
    assert_all_images_have_alt(html)
    assert_all_labelledby_refs_exist(html)

    css = File.read!(@css_path)
    assert css =~ "width: 2.75rem;"
    assert css =~ "min-width: 2.75rem;"
    assert css =~ "height: 2.75rem;"
  end

  test "reduce-motion setting renders root state and stylesheet suppression", %{conn: conn} do
    assert {:ok, _setting} =
             Settings.put("workspace.accessibility.reduce_motion", true, %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace")
    css = File.read!(@css_path)

    assert has_element?(view, "#workspace-shell[data-reduce-motion='true']")
    assert css =~ ~s(#workspace-shell[data-reduce-motion="true"])
    assert css =~ "transition-duration: 0.001ms !important"
    assert css =~ "animation-duration: 0.001ms !important"
    assert css =~ "scroll-behavior: auto !important"
  end

  test "approval handoff is a labelled focus-trapped dialog", %{conn: conn} do
    Application.delete_env(:allbert_assist, Runtime)
    configure_external()

    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Fetch https://example.com from the internet"})

    html = render_async(view, @runtime_async_timeout)

    assert html =~ "Approval Required"

    assert has_element?(
             view,
             "#approval-handoff[role='dialog'][aria-modal='true'][aria-labelledby='approval-title'][phx-hook='FocusTrap']"
           )

    assert has_element?(
             view,
             "#approval-details[aria-controls='approval-details-data'][aria-expanded='false']"
           )

    html =
      view
      |> element("#approval-details")
      |> render_click()

    assert html =~ ~s(id="approval-details-data")
    assert html =~ "Approval:"
    refute html =~ "%AllbertAssist.Intent.ApprovalHandoff"
    refute html =~ "render_hints:"
    assert has_element?(view, "#approval-details[aria-expanded='true']")
    assert_all_buttons_named(html)
    assert_all_labelledby_refs_exist(html)
  end

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/"], %{audit?: false})
  end

  defp assert_all_buttons_named(html) do
    missing =
      ~r/<button\b([^>]*)>(.*?)<\/button>/s
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.with_index()
      |> Enum.filter(fn {[attrs, body], _index} ->
        not has_attr?(attrs, "aria-label") and visible_text(body) == ""
      end)

    assert missing == []
  end

  defp assert_all_images_have_alt(html) do
    missing =
      ~r/<img\b([^>]*)>/s
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.with_index()
      |> Enum.filter(fn {[attrs], _index} -> not has_attr?(attrs, "alt") end)

    assert missing == []
  end

  defp assert_all_labelledby_refs_exist(html) do
    missing =
      ~r/aria-labelledby="([^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.flat_map(fn [refs] -> String.split(refs) end)
      |> Enum.reject(&String.contains?(html, ~s(id="#{&1}")))

    assert missing == []
  end

  defp has_attr?(attrs, attr), do: attrs =~ ~r/\s#{Regex.escape(attr)}(=|\s|>)/

  defp visible_text(body) do
    body
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
