defmodule AllbertAssist.Channels.ChannelParityTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.Channels.ChannelParity

  @shipped_plugins [
    AllbertAssist.Plugins.Telegram,
    AllbertAssist.Plugins.Email,
    AllbertAssist.Plugins.Discord,
    AllbertAssist.Plugins.Slack,
    AllbertAssist.Plugins.Matrix,
    AllbertAssist.Plugins.WhatsApp,
    AllbertAssist.Plugins.Signal,
    AllbertAssist.Plugins.TUI
  ]

  defmodule InvalidStreamingPlugin do
    use AllbertAssist.Plugin

    def plugin_id, do: "test.invalid_streaming"
    def display_name, do: "Invalid Streaming Test"
    def version, do: "1.0.0"
    def validate(_opts), do: :ok

    def channels do
      [
        %{
          channel_id: "invalid_streaming",
          provider: "test",
          primitives: [:typed_command, :list],
          threading: :reply_chain,
          streaming: :word_by_word,
          trust_class: :server_readable
        }
      ]
    end
  end

  defmodule RemoteLiveRegionPlugin do
    use AllbertAssist.Plugin

    def plugin_id, do: "test.remote_live_region"
    def display_name, do: "Remote Live Region Test"
    def version, do: "1.0.0"
    def validate(_opts), do: :ok

    def channels do
      [
        %{
          channel_id: "remote_live_region",
          provider: "test",
          primitives: [:typed_command, :list],
          threading: :reply_chain,
          streaming: :live_region,
          trust_class: :server_readable
        }
      ]
    end
  end

  defmodule InvalidStatusUpdatePlugin do
    use AllbertAssist.Plugin

    def plugin_id, do: "test.invalid_status_update"
    def display_name, do: "Invalid Status Update Test"
    def version, do: "1.0.0"
    def validate(_opts), do: :ok

    def channels do
      [
        %{
          channel_id: "invalid_status_update",
          provider: "test",
          primitives: [:typed_command, :list],
          threading: :reply_chain,
          status_update_mode: :overwrite_history,
          trust_class: :server_readable
        }
      ]
    end
  end

  test "matrix derives streaming posture and preserves the absent-field default" do
    descriptors = Enum.flat_map(@shipped_plugins, & &1.channels())
    rows = ChannelParity.matrix(registered_channels: descriptors)

    assert streaming_by_channel(rows) == %{
             "cli" => "turn_complete",
             "discord" => "progress_messages",
             "email" => "turn_complete",
             "live_view" => "live_region",
             "matrix" => "progress_messages",
             "signal" => "progress_messages",
             "slack" => "progress_messages",
             "telegram" => "progress_messages",
             "tui" => "live_region",
             "whatsapp" => "progress_messages"
           }

    assert status_update_by_channel(rows) == %{
             "cli" => "append_only",
             "discord" => "edit_in_place",
             "email" => "append_only",
             "live_view" => "append_only",
             "matrix" => "edit_in_place",
             "signal" => "append_only",
             "slack" => "edit_in_place",
             "telegram" => "edit_in_place",
             "tui" => "append_only",
             "whatsapp" => "append_only"
           }

    for channel <- ~w[telegram discord slack matrix] do
      descriptor = Enum.find(descriptors, &(&1.channel_id == channel))
      assert function_exported?(descriptor.adapter, :edit_outbound, 4)
    end

    assert :ok = ChannelParity.verify(registered_channels: descriptors)
  end

  test "verify rejects an unknown streaming declaration" do
    assert {:error, errors} =
             ChannelParity.verify(registered_channels: InvalidStreamingPlugin.channels())

    assert %{channel: "invalid_streaming", reason: :invalid_streaming} in errors
  end

  test "verify confines live regions to local surfaces and TUI" do
    assert {:error, errors} =
             ChannelParity.verify(registered_channels: RemoteLiveRegionPlugin.channels())

    assert %{channel: "remote_live_region", reason: :live_region_not_local} in errors
  end

  test "verify rejects an unknown status update declaration" do
    assert {:error, errors} =
             ChannelParity.verify(registered_channels: InvalidStatusUpdatePlugin.channels())

    assert %{channel: "invalid_status_update", reason: :invalid_status_update_mode} in errors
  end

  defp streaming_by_channel(rows), do: Map.new(rows, &{&1.channel, &1.streaming})

  defp status_update_by_channel(rows),
    do: Map.new(rows, &{&1.channel, &1.status_update_mode})
end
