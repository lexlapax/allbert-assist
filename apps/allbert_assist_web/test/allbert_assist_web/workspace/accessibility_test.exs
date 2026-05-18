defmodule AllbertAssistWeb.Workspace.AccessibilityTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.{Confirmations, Paths, Runtime, Settings}

  @runtime_async_timeout 10_000

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

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)
  end

  test "workspace shell renders named landmarks and controls", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/agent")

    assert has_element?(view, "#skip-to-content[href='#main-content']")
    assert has_element?(view, "main#main-content[tabindex='-1']")
    assert has_element?(view, "nav[aria-label='Primary']")
    assert has_element?(view, "img[alt='Allbert']")
    assert has_element?(view, "[role='group'][aria-label='Site theme']")
    assert has_element?(view, "button[aria-label='Use system theme']")
    assert has_element?(view, "button[aria-label='Use light theme']")
    assert has_element?(view, "button[aria-label='Use dark theme']")
    assert has_element?(view, "#workspace-shell[role='region']")
    assert has_element?(view, "#workspace-theme-toggle[aria-label]")
    assert has_element?(view, "label#agent-prompt-label[for='agent-prompt']")
    assert has_element?(view, "#agent-prompt[aria-labelledby='agent-prompt-label']")
    assert has_element?(view, "#agent-form[aria-busy='false']")

    assert_all_buttons_named(html)
    assert_all_images_have_alt(html)
    assert_all_labelledby_refs_exist(html)
  end

  test "approval handoff is a labelled focus-trapped dialog", %{conn: conn} do
    Application.delete_env(:allbert_assist, Runtime)
    configure_external()

    {:ok, view, _html} = live(conn, ~p"/agent")

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
