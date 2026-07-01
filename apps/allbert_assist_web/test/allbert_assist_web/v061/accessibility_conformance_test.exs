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

  test "system-theme high-contrast resolves to the dark-HC palette under OS dark" do
    css = File.read!(@css_path)

    # Inside @media (prefers-color-scheme: dark), a [data-theme="system"] high-contrast
    # rule must carry the dark-HC surfaces (black) + the re-resolved --workspace-*
    # aliases, so dark+HC users in system mode are not flipped to the light-HC white.
    assert css =~ ~s([data-theme="system"] [data-high-contrast="true"] {)

    [_, after_sel] =
      String.split(css, ~s([data-theme="system"] [data-high-contrast="true"] {), parts: 2)

    block = after_sel |> String.split("}", parts: 2) |> hd()
    assert block =~ "--allbert-surface-0: #000000;"
    assert block =~ "--workspace-accent: var(--allbert-accent);"

    IO.puts("dark-high-contrast-system-resolution-001 status=pass palette=dark_hc fallback=none")
  end

  test "high-contrast primary CTA meets WCAG AA by computed contrast ratio" do
    css = File.read!(@css_path)

    # The prior "contrast" check only grepped that the selector block existed — it
    # would pass against the pre-remediation buggy CSS. This computes the real WCAG
    # ratio for .workspace-button-primary (background var(--workspace-accent) =
    # var(--allbert-accent); text var(--allbert-accent-contrast)) under both HC blocks.
    light_hc = hc_block(css, ~s([data-high-contrast="true"]))
    assert light_hc =~ "--workspace-accent: var(--allbert-accent);"

    light_ratio =
      contrast_ratio(
        token_hex(light_hc, "--allbert-accent-contrast"),
        token_hex(light_hc, "--allbert-accent")
      )

    assert light_ratio >= 4.5,
           "light-HC primary CTA contrast #{Float.round(light_ratio, 2)}:1 is below WCAG AA 4.5:1"

    dark_hc = hc_block(css, ~s([data-theme="dark"][data-high-contrast="true"]))
    assert dark_hc =~ "--workspace-accent: var(--allbert-accent);"

    dark_ratio =
      contrast_ratio(
        token_hex(dark_hc, "--allbert-accent-contrast"),
        token_hex(dark_hc, "--allbert-accent")
      )

    assert dark_ratio >= 4.5,
           "dark-HC primary CTA contrast #{Float.round(dark_ratio, 2)}:1 is below WCAG AA 4.5:1"

    IO.puts(
      "a11y-contrast-ratio-computed-001 status=pass light=#{Float.round(light_ratio, 1)}:1 " <>
        "dark=#{Float.round(dark_ratio, 1)}:1"
    )
  end

  test "high-contrast semantic status colors meet WCAG AA on the HC surface" do
    css = File.read!(@css_path)
    hc = hc_block(css, ~s([data-high-contrast="true"]))

    # The HC surface is #ffffff; the semantic status foregrounds (warn/danger/success/
    # info), hardened in the HC block, must clear AA on it (the :root values were ~4.5:1).
    for token <- ~w(--allbert-warn --allbert-danger --allbert-success --allbert-info) do
      ratio = contrast_ratio(token_hex(hc, token), "#ffffff")

      assert ratio >= 4.5,
             "HC #{token} contrast #{Float.round(ratio, 2)}:1 is below WCAG AA 4.5:1"
    end

    IO.puts("a11y-status-contrast-hardened-001 status=pass tokens=warn,danger,success,info")
  end

  # Extract a CSS block body (up to the first `}`) for the rule whose selector list
  # begins with `selector`.
  defp hc_block(css, selector) do
    [_, after_sel] = String.split(css, selector, parts: 2)

    after_sel
    |> String.split("{", parts: 2)
    |> List.last()
    |> String.split("}", parts: 2)
    |> hd()
  end

  defp token_hex(block, name) do
    [_, hex] = Regex.run(~r/#{Regex.escape(name)}:\s*(#[0-9a-fA-F]{6})/, block)
    hex
  end

  defp contrast_ratio(hex1, hex2) do
    l1 = luminance(hex1)
    l2 = luminance(hex2)
    {lighter, darker} = if l1 >= l2, do: {l1, l2}, else: {l2, l1}
    (lighter + 0.05) / (darker + 0.05)
  end

  defp luminance("#" <> hex) do
    <<r::binary-2, g::binary-2, b::binary-2>> = hex

    0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
  end

  defp channel(hex_pair) do
    c = String.to_integer(hex_pair, 16) / 255
    if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
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
