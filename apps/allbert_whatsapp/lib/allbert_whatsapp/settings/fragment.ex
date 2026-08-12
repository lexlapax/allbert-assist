defmodule AllbertWhatsApp.Settings.Fragment do
  @moduledoc """
  Plugin-owned Settings Central fragment for the v0.53 WhatsApp channel.

  M4 owns the signed webhook substrate settings that already live in the core
  schema. M7 adds adapter/runtime settings for Cloud API delivery, identity
  mapping, approval rendering, and reply-chain quote degradation.
  """

  @settings_schema [
    %{key: "channels.whatsapp.enabled", type: :boolean, default: false},
    %{
      key: "channels.whatsapp.access_token_ref",
      type: :channel_secret_ref,
      default: "secret://channels/whatsapp/access_token",
      sensitive?: true
    },
    %{key: "channels.whatsapp.identity_map", type: :channel_identity_map, default: []},
    %{
      key: "channels.whatsapp.response_style",
      type: :enum,
      default: "always",
      allowed_values: ["always"]
    },
    %{
      key: "channels.whatsapp.max_text_bytes",
      type: :bounded_integer,
      default: 4096,
      min: 1,
      max: 4096
    },
    %{
      key: "channels.whatsapp.render_approval_buttons",
      type: :boolean,
      default: true
    },
    %{
      key: "channels.whatsapp.quote_ttl_ms",
      type: :bounded_integer,
      default: 86_400_000,
      min: 1_000,
      max: 86_400_000
    },
    %{
      key: "channels.whatsapp.graph_api_version",
      type: :enum,
      default: "v23.0",
      allowed_values: ["v23.0"]
    }
  ]

  @required_when_enabled [
    "access_token_ref",
    "phone_number_id"
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
