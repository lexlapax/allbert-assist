defmodule AllbertAssistWeb.V061.AccessibilityConformanceTest do
  @moduledoc """
  v0.61 M10.1 proof for the redesigned surface accessibility row.
  """
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.{Confirmations, Paths, Runtime, Session, Settings}

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @app_js_path Path.expand("../../../assets/js/app.js", __DIR__)

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root = Path.join(System.tmp_dir!(), "allbert-v061-a11y-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        {:ok, %{message: "Runtime LiveView response: #{request.text}", status: :completed}}
      end
    )

    _ = Session.clear_active_app("local", "web-local")

    on_exit(fn ->
      _ = Session.clear_active_app("local", "web-local")
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "redesigned pages keep focus, contrast, and reduced-motion accessibility", %{conn: conn} do
    for path <- [~p"/workspace", ~p"/jobs", ~p"/objectives"] do
      {:ok, view, html} = live(conn, path)

      assert has_element?(view, "#skip-to-content[href='#main-content']")
      assert has_element?(view, "main#main-content[tabindex='-1']")

      if path == ~p"/workspace" do
        assert has_element?(view, "#workspace-shell")
      else
        assert has_element?(view, "#operator-shell")
      end

      assert_all_buttons_named!(html)
      assert_all_labelledby_refs_exist!(html)
    end

    css = File.read!(@css_path)
    app_js = File.read!(@app_js_path)

    assert app_js =~ "FocusTrap"
    assert css =~ ~s([data-high-contrast="true"] {)
    assert css =~ ~s([data-theme="dark"] [data-high-contrast="true"] {)
    assert css =~ "@media (prefers-reduced-motion: reduce)"
    assert css =~ "transition-duration: 0.001ms !important"
    assert css =~ "animation-duration: 0.001ms !important"

    IO.puts(
      "a11y-focus-contrast-conformance-001 status=pass focus=true contrast=true reduced_motion=true"
    )
  end

  defp assert_all_buttons_named!(html) do
    missing =
      ~r/<button\b([^>]*)>(.*?)<\/button>/s
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.with_index()
      |> Enum.filter(fn {[attrs, body], _index} ->
        not has_attr?(attrs, "aria-label") and visible_text(body) == ""
      end)

    assert missing == []
  end

  defp assert_all_labelledby_refs_exist!(html) do
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
