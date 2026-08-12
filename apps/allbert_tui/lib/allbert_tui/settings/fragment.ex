defmodule AllbertTUI.Settings.Fragment do
  @moduledoc """
  Plugin-owned Settings Central fragment for the v0.55 terminal TUI channel.
  """

  @settings_schema [
    %{key: "channels.tui.enabled", type: :boolean, default: false},
    %{key: "channels.tui.profile", type: :string_or_empty, default: "default"},
    %{key: "channels.tui.identity_map", type: :channel_identity_map, default: []},
    %{
      key: "channels.tui.max_text_bytes",
      type: :bounded_integer,
      default: 12_000,
      min: 1,
      max: 32_000
    }
  ]

  def settings_schema, do: @settings_schema
end
