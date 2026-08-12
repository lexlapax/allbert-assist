defmodule AllbertTUI.Plugin do
  @moduledoc false

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.tui"

  @impl true
  def display_name, do: "Allbert Terminal TUI Channel"

  @impl true
  def version, do: "0.55.1"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def channels do
    [
      %{
        channel_id: "tui",
        provider: "terminal",
        adapter: AllbertTUI.Adapter,
        identity_bootstrap: AllbertTUI.IdentityBootstrap,
        input_receipt: AllbertTUI.InputReceipt,
        input_driver: AllbertTUI.InputDriver,
        child_spec: {AllbertTUI.Adapter, []},
        secret_refs: [],
        summary_fields: ["enabled", "profile"],
        settings_prefix: "channels.tui",
        identity_map_key: "channels.tui.identity_map",
        session_strategy: {:tui_session, prefix: "ch_tui_"},
        primitives: [:typed_command, :list],
        threading: :rich,
        streaming: :live_region,
        trust_class: :local,
        can_create_thread: true,
        plugin_id: plugin_id(),
        source: :shipped,
        status: :enabled
      }
    ]
  end

  @impl true
  # v1.4 M13: settings ownership moved to the pack FragmentOwner.
  def settings_schema, do: []
end
