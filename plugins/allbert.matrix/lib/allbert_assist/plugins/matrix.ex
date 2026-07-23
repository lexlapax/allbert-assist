defmodule AllbertAssist.Plugins.Matrix do
  @moduledoc false

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.matrix"

  @impl true
  def display_name, do: "Allbert Matrix Channel"

  @impl true
  def version, do: "0.53.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def channels do
    [
      %{
        channel_id: "matrix",
        provider: "matrix_client_server",
        adapter: AllbertAssist.Channels.Matrix.Adapter,
        child_spec: {AllbertAssist.Channels.Matrix.Adapter, []},
        secret_refs: ["channels.matrix.access_token_ref"],
        summary_fields: ["enabled", "homeserver_url", "allowed_room_ids"],
        settings_prefix: "channels.matrix",
        identity_map_key: "channels.matrix.identity_map",
        session_strategy: {:matrix_room, prefix: "ch_mx_"},
        primitives: [:typed_command, :link, :list],
        threading: :native_threads,
        streaming: :progress_messages,
        trust_class: :server_readable,
        can_create_thread: false,
        reply_key_type: :opaque_id,
        plugin_id: plugin_id(),
        source: :shipped,
        status: :enabled
      }
    ]
  end

  @impl true
  def actions, do: [AllbertAssist.Actions.Channels.MatrixDoctor]

  @impl true
  def settings_schema,
    do:
      AllbertMatrix.Settings.Fragment.settings_schema() ++
        AllbertAssist.Channels.Notify.settings_schema("matrix")
end
