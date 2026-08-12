defmodule AllbertSignal.Plugin do
  @moduledoc false

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.signal"

  @impl true
  def display_name, do: "Allbert Signal Channel"

  @impl true
  def version, do: "0.53.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def channels do
    [
      %{
        channel_id: "signal",
        provider: "signal_cli_jsonrpc",
        adapter: AllbertSignal.Adapter,
        doctor: AllbertSignal.Doctor,
        child_spec: {AllbertSignal.Supervisor, []},
        secret_refs: ["channels.signal.control_auth_ref"],
        summary_fields: ["enabled", "account_identifier", "control_mode", "socket_path"],
        settings_prefix: "channels.signal",
        identity_map_key: "channels.signal.identity_map",
        session_strategy: {:signal_aci, prefix: "ch_si_"},
        primitives: [:typed_command, :link, :list],
        threading: :reply_chain,
        streaming: :progress_messages,
        trust_class: :e2ee_origin,
        can_create_thread: false,
        reply_key_type: :timestamp,
        plugin_id: plugin_id(),
        source: :shipped,
        status: :enabled,
        # v1.4 M13: this pack is `native_effectful` (catalog.json) and starts
        # its own adapter through AllbertSignal.EffectSupervisor. Tells the
        # residual's aggregate AllbertAssist.Channels.channel_child_specs/1 to
        # skip this descriptor so the adapter is never started twice.
        supervised_by: :pack
      }
    ]
  end

  @impl true
  def actions do
    [
      AllbertSignal.Actions.Doctor,
      AllbertSignal.Actions.LinkDevice
    ]
  end

  @impl true
  # v1.4 M13: settings ownership moved to the pack FragmentOwner.
  def settings_schema, do: []
end
