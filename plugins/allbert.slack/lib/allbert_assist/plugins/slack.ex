defmodule AllbertAssist.Plugins.Slack do
  @moduledoc false

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.slack"

  @impl true
  def display_name, do: "Allbert Slack Channel"

  @impl true
  def version, do: "0.52.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def channels do
    [
      %{
        channel_id: "slack",
        provider: "slack_socket_mode",
        adapter: AllbertAssist.Channels.Slack.Adapter,
        child_spec: {AllbertAssist.Channels.Slack.Adapter, []},
        secret_refs: [
          "channels.slack.bot_token_ref",
          "channels.slack.app_token_ref"
        ],
        summary_fields: [
          "enabled",
          "response_style",
          "workspace_team_id",
          "allowed_channel_ids"
        ],
        settings_prefix: "channels.slack",
        identity_map_key: "channels.slack.identity_map",
        session_strategy: {:slack_native_thread, prefix: "ch_sl_"},
        primitives: [:button, :typed_command, :list],
        threading: :native_threads,
        streaming: :progress_messages,
        status_update_mode: :edit_in_place,
        trust_class: :server_readable,
        can_create_thread: false,
        reply_key_type: :timestamp,
        quote_ttl_ms: 86_400_000,
        plugin_id: plugin_id(),
        source: :shipped,
        status: :enabled
      }
    ]
  end

  @impl true
  def actions, do: [AllbertAssist.Actions.Channels.SlackDoctor]

  @impl true
  def settings_schema,
    do:
      AllbertSlack.Settings.Fragment.settings_schema() ++
        AllbertAssist.Channels.Notify.settings_schema("slack")
end
