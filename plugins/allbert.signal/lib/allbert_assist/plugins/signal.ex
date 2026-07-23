defmodule AllbertAssist.Plugins.Signal do
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
        adapter: AllbertAssist.Channels.Signal.Adapter,
        child_spec: {AllbertAssist.Channels.Signal.Supervisor, []},
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
        status: :enabled
      }
    ]
  end

  @impl true
  def actions do
    [
      AllbertAssist.Actions.Channels.SignalDoctor,
      AllbertAssist.Actions.Channels.SignalLinkDevice
    ]
  end

  @impl true
  def settings_schema,
    do:
      AllbertSignal.Settings.Fragment.settings_schema() ++
        AllbertAssist.Channels.Notify.settings_schema("signal")
end
