defmodule AllbertSlack.Settings.Fragment do
  @moduledoc """
  Plugin-owned Settings Central fragment for the v0.52 Slack channel.
  """

  @settings_schema [
    %{key: "channels.slack.enabled", type: :boolean, default: false},
    %{
      key: "channels.slack.bot_token_ref",
      type: :channel_secret_ref,
      default: "secret://channels/slack/bot_token",
      sensitive?: true
    },
    %{
      key: "channels.slack.app_token_ref",
      type: :channel_secret_ref,
      default: "secret://channels/slack/app_token",
      sensitive?: true
    },
    %{
      key: "channels.slack.signing_secret_ref",
      type: :channel_secret_ref,
      default: "secret://channels/slack/signing_secret",
      sensitive?: true,
      writable?: false
    },
    %{key: "channels.slack.workspace_team_id", type: :string_or_empty, default: ""},
    %{key: "channels.slack.allowed_channel_ids", type: :string_list, default: []},
    %{
      key: "channels.slack.response_style",
      type: :enum,
      default: "mention",
      allowed_values: ["mention", "always", "dm_only"]
    },
    %{
      key: "channels.slack.max_text_bytes",
      type: :bounded_integer,
      default: 3000,
      min: 1,
      max: 3000
    },
    %{key: "channels.slack.render_approval_buttons", type: :boolean, default: true},
    %{key: "channels.slack.identity_map", type: :channel_identity_map, default: []},
    %{key: "channels.slack.socket_mode.enabled", type: :boolean, default: true, writable?: false},
    %{
      key: "channels.slack.socket_mode.reconnect_max_backoff_ms",
      type: :bounded_integer,
      default: 30_000,
      min: 250,
      max: 300_000
    }
  ]

  @required_when_enabled [
    "bot_token_ref",
    "app_token_ref",
    "workspace_team_id",
    "allowed_channel_ids"
  ]

  @spec settings_schema() :: [map()]
  def settings_schema, do: @settings_schema

  @spec required_when_enabled(map()) :: [atom()]
  def required_when_enabled(settings) when is_map(settings) do
    if Map.get(settings, "enabled", false) do
      Enum.flat_map(@required_when_enabled, fn key ->
        case Map.get(settings, key) do
          value when value in [nil, "", []] -> [String.to_atom("missing_" <> key)]
          _value -> []
        end
      end)
    else
      []
    end
  end

  def required_when_enabled(_settings), do: [:invalid_settings]
end
