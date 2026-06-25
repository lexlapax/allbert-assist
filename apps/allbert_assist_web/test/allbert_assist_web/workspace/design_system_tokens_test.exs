defmodule AllbertAssistWeb.Workspace.DesignSystemTokensTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  test "stylesheet defines token scales globally before the workspace shell" do
    css = File.read!(@css_path)
    root = css_block!(css, ":root")
    workspace_shell = css_block!(css, "#workspace-shell")

    assert index_of!(css, ":root {") < index_of!(css, "#workspace-shell {")
    assert root =~ "--allbert-surface-0"
    assert root =~ "--allbert-font-size-md"
    assert root =~ "--allbert-line-height-body"
    assert root =~ "--allbert-space-4"
    assert root =~ "--allbert-radius-panel"
    assert root =~ "--allbert-motion-duration-base"
    assert root =~ "--allbert-shadow-panel"
    assert root =~ "--allbert-focus-ring"

    refute workspace_shell =~ "--allbert-surface-0"
    refute workspace_shell =~ "--allbert-font-size-md:"
  end

  test "high contrast and reduced motion are global design states" do
    css = File.read!(@css_path)

    assert css =~ ~s([data-high-contrast="true"] {)
    assert css =~ ~s([data-theme="dark"] [data-high-contrast="true"] {)
    assert css =~ "@media (prefers-contrast: more)"
    refute css =~ ~s(#workspace-shell[data-high-contrast="true"] {\n  --allbert-surface-0)

    assert css =~ ~s([data-reduce-motion="true"],)
    assert css =~ "@media (prefers-reduced-motion: reduce)"
    assert css =~ "transition-duration: 0.001ms !important"
    assert css =~ "animation-duration: 0.001ms !important"
    assert css =~ "scroll-behavior: auto !important"
  end

  test "changed interactive controls consume motion tokens" do
    css = File.read!(@css_path)

    assert css_block!(css, ".allbert-icon-button") =~
             "var(--allbert-motion-duration-base) var(--allbert-motion-ease-standard)"

    assert css_block!(css, ".workspace-button") =~
             "var(--allbert-motion-duration-base) var(--allbert-motion-ease-standard)"

    assert css_block!(css, ".workspace-button-compact") =~ "min-height: 2rem"

    assert css_block!(css, ".workspace-copy-target") =~
             "var(--allbert-motion-duration-fast) var(--allbert-motion-ease-standard)"
  end

  test "M13.1B operator surfaces do not use raw daisy button classes" do
    for path <- m131b_operator_surface_paths() do
      source = File.read!(path)

      refute source =~ ~r/class=\{?\s*"[^"]*\bbtn\b/,
             "#{Path.relative_to_cwd(path)} still declares raw btn classes"
    end
  end

  defp css_block!(css, selector) do
    pattern = ~r/#{Regex.escape(selector)}\s*\{(?<body>.*?)\n\}/s

    case Regex.named_captures(pattern, css) do
      %{"body" => body} -> body
      nil -> flunk("missing CSS block for #{selector}")
    end
  end

  defp index_of!(css, needle) do
    case :binary.match(css, needle) do
      {index, _length} -> index
      :nomatch -> flunk("missing #{needle}")
    end
  end

  defp m131b_operator_surface_paths do
    lib_dir = Path.expand("../../../lib/allbert_assist_web", __DIR__)

    [
      "controllers/page_html/home.html.heex",
      "components/core_components.ex",
      "components/layouts.ex",
      "workspace/components/operator_panels.ex",
      "workspace/components/settings_central.ex",
      "workspace/components/onboarding.ex",
      "workspace/components/template_create.ex",
      "workspace/components/plan_build.ex"
    ]
    |> Enum.map(&Path.join(lib_dir, &1))
  end
end
