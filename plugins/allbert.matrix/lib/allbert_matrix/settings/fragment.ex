defmodule AllbertMatrix.Settings.Fragment do
  @moduledoc """
  Plugin-owned Settings Central fragment for the v0.53 Matrix channel.

  M6 intentionally supports unencrypted rooms only. Settings Central remains the
  write, validation, audit, and redaction authority.
  """

  @settings_schema [
    %{key: "channels.matrix.enabled", type: :boolean, default: false},
    %{key: "channels.matrix.homeserver_url", type: :string_or_empty, default: ""},
    %{
      key: "channels.matrix.access_token_ref",
      type: :channel_secret_ref,
      default: "secret://channels/matrix/access_token",
      sensitive?: true
    },
    %{key: "channels.matrix.user_id", type: :string_or_empty, default: ""},
    %{key: "channels.matrix.allowed_room_ids", type: :string_list, default: []},
    %{
      key: "channels.matrix.response_style",
      type: :enum,
      default: "always",
      allowed_values: ["always"]
    },
    %{
      key: "channels.matrix.max_text_bytes",
      type: :bounded_integer,
      default: 4000,
      min: 1,
      max: 8000
    },
    %{key: "channels.matrix.identity_map", type: :channel_identity_map, default: []},
    %{
      key: "channels.matrix.sync_poll_interval_ms",
      type: :bounded_integer,
      default: 2000,
      min: 250,
      max: 300_000
    },
    %{
      key: "channels.matrix.sync_timeout_ms",
      type: :bounded_integer,
      default: 30_000,
      min: 0,
      max: 300_000
    }
  ]

  @required_when_enabled [
    "homeserver_url",
    "access_token_ref",
    "allowed_room_ids"
  ]

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
