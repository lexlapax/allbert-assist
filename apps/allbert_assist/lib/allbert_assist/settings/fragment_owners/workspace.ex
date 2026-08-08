defmodule AllbertAssist.Settings.FragmentOwners.Workspace do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "workspace.accessibility.high_contrast" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "workspace.accessibility.reduce_motion" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "workspace.agui_bridge.enabled" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "workspace.canvas.max_tiles_per_thread" => %{
      default: 64,
      max: 256,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "workspace.canvas.tile_body_max_bytes" => %{
      default: 65536,
      max: 262_144,
      min: 1024,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "workspace.ephemeral.max_active_per_thread" => %{
      default: 16,
      max: 64,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "workspace.fragment.emission_enabled" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "workspace.fragment.payload_max_bytes" => %{
      default: 65536,
      max: 262_144,
      min: 1024,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "workspace.fragment.rate_limit_per_second" => %{
      default: 10,
      max: 1000,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "workspace.fragment.receiver_rate_limit_per_second" => %{
      default: 10,
      max: 1000,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "workspace.fragment.signing_secret" => %{
      default: nil,
      sensitive?: true,
      type: :hex_secret_or_nil,
      writable?: false
    },
    "workspace.layout.override_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "workspace.mobile.breakpoint_px" => %{
      default: 768,
      sensitive?: false,
      type: :positive_integer,
      writable?: false
    },
    "workspace.offline.enabled" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "workspace.offline.indexeddb_quota_mb" => %{
      default: 32,
      max: 256,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "workspace.signal_bridge.log_dropped_fragments" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "workspace.theme.active" => %{
      default: nil,
      sensitive?: false,
      type: :string_or_nil,
      writable?: true
    },
    "workspace.theme.enabled_snippets" => %{
      default: [],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "workspace.theme.mode" => %{
      allowed_values: ["light", "dark", "system"],
      default: "system",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "workspace.theme.snippets_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    }
  }
  @defaults %{
    "workspace" => %{
      "accessibility" => %{"high_contrast" => false, "reduce_motion" => false},
      "agui_bridge" => %{"enabled" => true},
      "canvas" => %{"max_tiles_per_thread" => 64, "tile_body_max_bytes" => 65536},
      "ephemeral" => %{"max_active_per_thread" => 16},
      "fragment" => %{
        "emission_enabled" => true,
        "payload_max_bytes" => 65536,
        "rate_limit_per_second" => 10,
        "receiver_rate_limit_per_second" => 10,
        "signing_secret" => nil
      },
      "layout" => %{"override_enabled" => false},
      "mobile" => %{"breakpoint_px" => 768},
      "offline" => %{"enabled" => true, "indexeddb_quota_mb" => 32},
      "signal_bridge" => %{"log_dropped_fragments" => true},
      "theme" => %{
        "active" => nil,
        "enabled_snippets" => [],
        "mode" => "system",
        "snippets_enabled" => false
      }
    }
  }
  @safe_write_keys [
    "workspace.theme.mode",
    "workspace.theme.active",
    "workspace.theme.snippets_enabled",
    "workspace.theme.enabled_snippets",
    "workspace.layout.override_enabled",
    "workspace.canvas.max_tiles_per_thread",
    "workspace.canvas.tile_body_max_bytes",
    "workspace.ephemeral.max_active_per_thread",
    "workspace.fragment.emission_enabled",
    "workspace.fragment.rate_limit_per_second",
    "workspace.fragment.receiver_rate_limit_per_second",
    "workspace.fragment.payload_max_bytes",
    "workspace.offline.enabled",
    "workspace.offline.indexeddb_quota_mb",
    "workspace.accessibility.high_contrast",
    "workspace.accessibility.reduce_motion",
    "workspace.agui_bridge.enabled",
    "workspace.signal_bridge.log_dropped_fragments"
  ]
  @safe_write_rows [
    {455, "workspace.theme.mode"},
    {456, "workspace.theme.active"},
    {457, "workspace.theme.snippets_enabled"},
    {458, "workspace.theme.enabled_snippets"},
    {459, "workspace.layout.override_enabled"},
    {460, "workspace.canvas.max_tiles_per_thread"},
    {461, "workspace.canvas.tile_body_max_bytes"},
    {462, "workspace.ephemeral.max_active_per_thread"},
    {463, "workspace.fragment.emission_enabled"},
    {464, "workspace.fragment.rate_limit_per_second"},
    {465, "workspace.fragment.receiver_rate_limit_per_second"},
    {466, "workspace.fragment.payload_max_bytes"},
    {467, "workspace.offline.enabled"},
    {468, "workspace.offline.indexeddb_quota_mb"},
    {469, "workspace.accessibility.high_contrast"},
    {470, "workspace.accessibility.reduce_motion"},
    {471, "workspace.agui_bridge.enabled"},
    {472, "workspace.signal_bridge.log_dropped_fragments"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:workspace",
      owner: "workspace",
      source: :core,
      group: "workspace",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Workspace"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
