defmodule AllbertAssistWeb.Workspace.VisualHierarchyTest do
  @moduledoc """
  v0.61 M8 proof: the visual-hierarchy craft pass gives the redesigned surface cards
  Direction C depth from the promoted tokens (no hardcoded radii/shadows), primary
  cards read as larger panels, and empty/first-run states are soft, legible cards.
  """
  use ExUnit.Case, async: true

  @moduletag :v061_hierarchy

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  test "card surfaces consume Direction C depth tokens, not hardcoded radii/shadows" do
    block = css_block!(".workspace-error-callout")

    assert block =~ "border: var(--allbert-border-width) solid var(--workspace-border);"
    assert block =~ "border-radius: var(--allbert-radius-control);"
    assert block =~ "box-shadow: var(--allbert-shadow-sm);"
  end

  test "primary cards read as larger Direction C panels" do
    assert css_block!(".workspace-card") =~ "border-radius: var(--allbert-radius-panel);"
  end

  test "empty/first-run states are soft Direction C cards" do
    block = css_block!(".workspace-empty-state")

    assert block =~ "border-radius: var(--allbert-radius-panel);"
    assert block =~ "border-style: dashed;"

    IO.puts(
      "design-tokens-global-conformance-001 status=pass surfaces=cards,empty-state depth=tokens"
    )
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
