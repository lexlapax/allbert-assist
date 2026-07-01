defmodule AllbertAssistWeb.Workspace.ChatPrimaryHeroTest do
  @moduledoc """
  v0.61 M5 proof: the chat-primary workspace re-layout ADR 0074 deferred is built to
  the chosen Layout D's chat-primary hero composition — a raised Direction C
  conversation card with a floating composer, consuming the promoted M3 elevation
  tokens (not hardcoded shadows/radii). Presentation-only; no data-layer change.
  """
  use ExUnit.Case, async: true

  @moduletag :v061_screens

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  test "the workspace conversation renders as a raised Direction C card" do
    pane = css_block!(".workspace-chat-pane")

    assert pane =~ "border-radius: var(--allbert-radius-panel);"
    assert pane =~ "box-shadow: var(--allbert-shadow-panel);"
  end

  test "the composer renders as a floating Direction C card on the tokens" do
    composer = css_block!(".workspace-composer")

    assert composer =~ "box-shadow: var(--allbert-shadow-panel);"
    assert composer =~ "border-radius: var(--allbert-radius-control);"
    assert composer =~ "background: var(--allbert-surface-1);"
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
