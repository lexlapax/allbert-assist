defmodule AllbertDiscord.Settings.Fragment do
  @moduledoc """
  Plugin-owned Settings Central fragment for the v0.52 Discord channel.

  The fragment contributes only the `channels.discord.*` subtree. Settings
  Central remains the write, validation, audit, and redaction authority.
  """

  @settings_schema [
    %{key: "channels.discord.enabled", type: :boolean, default: false},
    %{
      key: "channels.discord.bot_token_ref",
      type: :channel_secret_ref,
      default: "secret://channels/discord/bot_token",
      sensitive?: true
    },
    %{key: "channels.discord.application_id", type: :string_or_empty, default: ""},
    %{key: "channels.discord.allowed_guild_ids", type: :string_list, default: []},
    %{key: "channels.discord.allowed_channel_ids", type: :string_list, default: []},
    %{
      key: "channels.discord.response_style",
      type: :enum,
      default: "mention",
      allowed_values: ["mention", "always", "dm_only"]
    },
    %{
      key: "channels.discord.max_text_bytes",
      type: :bounded_integer,
      default: 2000,
      min: 1,
      max: 2000
    },
    %{key: "channels.discord.render_approval_buttons", type: :boolean, default: true},
    %{key: "channels.discord.identity_map", type: :channel_identity_map, default: []},
    %{
      key: "channels.discord.gateway_intents",
      type: :string_list,
      default: ["guild_messages", "direct_messages", "message_content"]
    },
    %{
      key: "channels.discord.gateway.reconnect_max_backoff_ms",
      type: :bounded_integer,
      default: 30_000,
      min: 250,
      max: 300_000
    },
    %{key: "channels.discord.gateway.heartbeat_jitter", type: :boolean, default: true}
  ]

  @required_when_enabled [
    "bot_token_ref",
    "application_id",
    "allowed_guild_ids"
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
