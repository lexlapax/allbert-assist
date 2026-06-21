defmodule AllbertAssist.Plugins.TUI do
  @moduledoc false

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.tui"

  @impl true
  def display_name, do: "Allbert Terminal TUI Channel"

  @impl true
  def version, do: "0.55.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def channels do
    [
      %{
        channel_id: "tui",
        provider: "terminal",
        adapter: AllbertAssist.Channels.TUI.Adapter,
        child_spec: {AllbertAssist.Channels.TUI.Adapter, []},
        secret_refs: [],
        summary_fields: ["enabled", "profile"],
        settings_prefix: "channels.tui",
        identity_map_key: "channels.tui.identity_map",
        session_strategy: {:tui_session, prefix: "ch_tui_"},
        primitives: [:typed_command, :list],
        threading: :rich,
        trust_class: :local,
        can_create_thread: true,
        plugin_id: plugin_id(),
        source: :shipped,
        status: :enabled
      }
    ]
  end

  @impl true
  def settings_schema, do: AllbertTUI.Settings.Fragment.settings_schema()
end
