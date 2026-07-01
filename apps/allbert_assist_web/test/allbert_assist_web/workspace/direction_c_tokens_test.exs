defmodule AllbertAssistWeb.Workspace.DirectionCTokensTest do
  @moduledoc """
  v0.61 M3 proof: the operator-chosen Direction C (Soft Modern Depth) visual
  language is promoted from the disposable `[data-visual-direction="c"]` preview
  delta into the canonical first-class `:root` (and dark) `--allbert-*` defaults,
  and its four Direction C patterns are wired — two reusable registry components
  (`elevated_card`, `nav_pill`) plus two markers carried on the richer native
  surfaces (`chat-primary-hero` on the chat pane, `trust-soft-card` on the policy
  panel).

  Scoped to the `:root` / `[data-theme="dark"]` blocks so it proves *promotion*,
  not mere presence (the values also exist in the still-live c preview block until
  the M10 preview retirement).
  """
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssistWeb.Workspace.Components.Patterns

  @moduletag :v061_visual_tokens

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  defmodule DirectionCHost do
    use Phoenix.Component

    alias AllbertAssistWeb.Workspace.Components.Patterns

    def render(assigns) do
      ~H"""
      <Patterns.elevated_card id="dc-card" title="Panel">
        <p>Elevated body</p>
      </Patterns.elevated_card>
      <Patterns.nav_pill id="dc-pill" label="Workspace" navigate="/workspace" active?={true} />
      """
    end
  end

  test "Direction C structural values are promoted into the canonical :root defaults" do
    root = css_block!(":root")

    assert root =~ "--allbert-font-family: ui-rounded,"
    assert root =~ "--allbert-density: 1.1;"
    assert root =~ "--allbert-radius-control: 0.875rem;"
    assert root =~ "--allbert-radius-panel: 1.25rem;"
    assert root =~ "--allbert-radius-modal: 1.25rem;"
    assert root =~ "--allbert-radius-drawer: 1.25rem;"
    assert root =~ "--allbert-motion-duration-fast: 140ms;"
    assert root =~ "--allbert-motion-duration-base: 200ms;"
    assert root =~ "--allbert-motion-duration-slow: 300ms;"
    assert root =~ "--allbert-motion-ease-standard: cubic-bezier(0.2, 0.8, 0.2, 1);"
    assert root =~ "--allbert-motion-ease-emphasis: cubic-bezier(0.34, 1.4, 0.64, 1);"
    assert root =~ "--allbert-shadow-panel: 0 18px 40px -12px rgb(60 40 120 / 28%);"
  end

  test "Direction C light tonal surfaces are promoted into :root" do
    root = css_block!(":root")

    assert root =~ "--allbert-surface-0: #f2f1fb;"
    assert root =~ "--allbert-surface-2: #e8e5f7;"
    assert root =~ "--allbert-text-strong: #1c1830;"
    assert root =~ "--allbert-text-soft: #5b5478;"
    assert root =~ "--allbert-line: #ddd8f0;"
    assert root =~ "--allbert-accent: #7c6cf0;"
    assert root =~ "--allbert-accent-soft: #ece9fd;"
  end

  test "Direction C dark tonal surfaces are promoted into the dark a11y-axis set" do
    dark = css_block!(~s([data-theme="dark"]))

    assert dark =~ "--allbert-surface-0: #14121f;"
    assert dark =~ "--allbert-surface-1: #1c1930;"
    assert dark =~ "--allbert-surface-2: #251f3d;"
    assert dark =~ "--allbert-text-strong: #efeafc;"
    assert dark =~ "--allbert-accent: #a99bf7;"
    assert dark =~ "--allbert-line: #332c52;"
  end

  test "high-contrast and reduced-motion a11y axes still hold over the promoted tokens" do
    css = File.read!(@css_path)

    assert css =~ ~s([data-high-contrast="true"] {)
    assert css =~ ~s([data-theme="dark"] [data-high-contrast="true"] {)
    assert css =~ "@media (prefers-reduced-motion: reduce)"
    assert css =~ "transition-duration: 0.001ms !important"

    # The high-contrast block must redeclare the --workspace-* aliases so HC wins over
    # the promoted Direction C :root values (which otherwise resolve once at :root to
    # violet and would leave HC-mode buttons/content below WCAG AA).
    hc = css_block!(~s([data-high-contrast="true"]))
    assert hc =~ "--workspace-bg: var(--allbert-surface-0);"
    assert hc =~ "--workspace-fg: var(--allbert-text-strong);"
    assert hc =~ "--workspace-accent: var(--allbert-accent);"
    assert hc =~ "--workspace-border: var(--allbert-line);"
  end

  test "the Direction C pattern classes consume the promoted tokens" do
    for {selector, token} <- [
          {".allbert-elevated-card", "var(--allbert-shadow-panel)"},
          {".allbert-nav-pill", "var(--allbert-radius-pill)"},
          {".allbert-trust-card", "var(--allbert-surface-1)"},
          # chat-primary-hero is carried on the native chat pane, not a component.
          {".workspace-chat-pane", "var(--allbert-shadow-panel)"}
        ] do
      assert css_block!(selector) =~ token,
             "#{selector} must consume the promoted #{token} token"
    end
  end

  test "the Direction C patterns are wired: two reusable components + two native markers" do
    html = render_component(&DirectionCHost.render/1, %{})

    # Two reusable registry components render with their pattern markers.
    assert html =~ ~s(data-workspace-pattern="elevated-card")
    assert html =~ ~s(data-workspace-pattern="nav-pill")
    assert length(String.split(html, ~s(data-workspace-variant="direction-c"))) == 3
    assert html =~ ~s(aria-current="page")

    # The other two patterns are carried on the richer native surfaces (not
    # standalone components): chat-primary-hero on the chat pane, trust-soft-card on
    # the surface-policy panel.
    lib = Path.expand("../../../lib/allbert_assist_web/workspace/components", __DIR__)
    chat = File.read!(Path.join(lib, "chat.ex"))
    panels = File.read!(Path.join(lib, "operator_panels.ex"))

    assert chat =~ ~s(data-workspace-pattern="chat-primary-hero")
    assert panels =~ ~s(data-workspace-pattern="trust-soft-card")

    IO.puts(
      "visual-language-direction-c-tokens-first-class-001 status=pass components=2 markers=2 " <>
        "promoted=root+dark authority=none"
    )
  end

  test "the variant class helpers stay behind the registry" do
    assert Patterns.elevated_card_class() == ["allbert-elevated-card", nil]
    assert Patterns.elevated_card_class("extra") == ["allbert-elevated-card", "extra"]
    assert Patterns.nav_pill_class(true) == ["allbert-nav-pill", "allbert-nav-pill-active", nil]
    assert Patterns.nav_pill_class(false) == ["allbert-nav-pill", false, nil]
  end

  defp css_block!(selector) do
    css = File.read!(@css_path)
    pattern = ~r/#{Regex.escape(selector)}\s*\{(?<body>.*?)\n\}/s

    case Regex.named_captures(pattern, css) do
      %{"body" => body} -> body
      nil -> flunk("missing CSS block for #{selector}")
    end
  end
end
