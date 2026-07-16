defmodule AllbertAssist.Workspace.CliOneshotSurfacingTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Marketplace.Panels.Catalog
  alias AllbertAssist.Workspace.DiscoverySuggestions

  @moduledoc """
  F4: a one-off CLI command boots the embedded runtime and, during app registration,
  used to eagerly run the marketplace catalog actions + a discovery DB query + MCP config
  resolves whose rendered content a headless command never uses. Under `:cli_oneshot?`
  those leaf builders emit their same-id empty-state surface instead — the web still
  re-renders the real content live under `serve`.
  """

  setup do
    Application.put_env(:allbert_assist, :cli_oneshot?, true)
    on_exit(fn -> Application.delete_env(:allbert_assist, :cli_oneshot?) end)
    :ok
  end

  test "the marketplace catalog panel skips its action runs (same id, empty state)" do
    node = Catalog.node(%{})
    assert node.id == "marketplace-catalog"
    assert node.props.body =~ "0 reviewed entries"
  end

  test "the discovery suggestions panel skips its DB query (same id, empty state)" do
    surface = DiscoverySuggestions.surface(%{})
    assert surface.id == :core_discovery_suggestions_panel
    assert hd(surface.nodes).props.body =~ "No pending suggestions"
  end
end
