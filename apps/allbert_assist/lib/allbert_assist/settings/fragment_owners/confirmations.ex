defmodule AllbertAssist.Settings.FragmentOwners.Confirmations do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "confirmations.allow_cli_approval" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "confirmations.allow_cross_channel_approval" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "confirmations.allow_liveview_approval" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "confirmations.auto_expire_on_startup" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "confirmations.default_ttl_minutes" => %{
      default: 1440,
      sensitive?: false,
      type: :positive_integer,
      writable?: true
    },
    "confirmations.require_reason_for_denial" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "confirmations.show_redacted_params" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    }
  }
  @defaults %{
    "confirmations" => %{
      "allow_cli_approval" => true,
      "allow_cross_channel_approval" => true,
      "allow_liveview_approval" => true,
      "auto_expire_on_startup" => true,
      "default_ttl_minutes" => 1440,
      "require_reason_for_denial" => false,
      "show_redacted_params" => true
    }
  }
  @safe_write_keys [
    "confirmations.default_ttl_minutes",
    "confirmations.auto_expire_on_startup",
    "confirmations.require_reason_for_denial",
    "confirmations.show_redacted_params",
    "confirmations.allow_cli_approval",
    "confirmations.allow_liveview_approval",
    "confirmations.allow_cross_channel_approval"
  ]
  @safe_write_rows [
    {390, "confirmations.default_ttl_minutes"},
    {391, "confirmations.auto_expire_on_startup"},
    {392, "confirmations.require_reason_for_denial"},
    {393, "confirmations.show_redacted_params"},
    {394, "confirmations.allow_cli_approval"},
    {395, "confirmations.allow_liveview_approval"},
    {396, "confirmations.allow_cross_channel_approval"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:confirmations",
      owner: "confirmations",
      source: :core,
      group: "confirmations",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Confirmations"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
