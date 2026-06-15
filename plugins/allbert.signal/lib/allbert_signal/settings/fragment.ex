defmodule AllbertSignal.Settings.Fragment do
  @moduledoc """
  Plugin-owned Settings Central fragment for the v0.53 Signal channel.
  """

  @settings_schema [
    %{key: "channels.signal.enabled", type: :boolean, default: false},
    %{key: "channels.signal.account_identifier", type: :string_or_empty, default: ""},
    %{key: "channels.signal.local_aci", type: :string_or_empty, default: ""},
    %{key: "channels.signal.daemon_path", type: :string, default: "signal-cli"},
    %{key: "channels.signal.data_dir", type: :string_or_empty, default: ""},
    %{
      key: "channels.signal.control_mode",
      type: :enum,
      default: "socket",
      allowed_values: ["socket", "loopback_http", "stub"]
    },
    %{key: "channels.signal.socket_path", type: :string_or_empty, default: ""},
    %{key: "channels.signal.loopback_http_base_url", type: :string_or_empty, default: ""},
    %{
      key: "channels.signal.control_auth_ref",
      type: :channel_secret_ref,
      default: "secret://channels/signal/control_auth",
      sensitive?: true
    },
    %{key: "channels.signal.allowed_aci_ids", type: :string_list, default: []},
    %{key: "channels.signal.identity_map", type: :channel_identity_map, default: []},
    %{
      key: "channels.signal.response_style",
      type: :enum,
      default: "always",
      allowed_values: ["always"]
    },
    %{
      key: "channels.signal.max_text_bytes",
      type: :bounded_integer,
      default: 4000,
      min: 1,
      max: 4000
    },
    %{
      key: "channels.signal.receive_mode",
      type: :enum,
      default: "on-start",
      allowed_values: ["on-start", "manual"]
    }
  ]

  @required_when_enabled [
    "account_identifier",
    "control_mode"
  ]

  def settings_schema, do: @settings_schema

  @spec required_when_enabled(map()) :: [atom()]
  def required_when_enabled(settings) when is_map(settings) do
    if Map.get(settings, "enabled", false) do
      @required_when_enabled
      |> Enum.flat_map(fn key ->
        case Map.get(settings, key) do
          value when value in [nil, "", []] -> [String.to_atom("missing_" <> key)]
          _value -> []
        end
      end)
      |> Kernel.++(control_diagnostics(settings))
    else
      []
    end
  end

  def required_when_enabled(_settings), do: [:invalid_settings]

  defp control_diagnostics(%{"control_mode" => "loopback_http"} = settings) do
    []
    |> maybe_missing(Map.get(settings, "loopback_http_base_url"), :missing_loopback_http_base_url)
    |> maybe_missing(Map.get(settings, "control_auth_ref"), :missing_control_auth_ref)
  end

  defp control_diagnostics(%{"control_mode" => "socket"}), do: []
  defp control_diagnostics(%{"control_mode" => "stub"}), do: []
  defp control_diagnostics(_settings), do: [:invalid_control_mode]

  defp maybe_missing(diagnostics, value, diagnostic) when value in [nil, "", []],
    do: diagnostics ++ [diagnostic]

  defp maybe_missing(diagnostics, _value, _diagnostic), do: diagnostics
end
