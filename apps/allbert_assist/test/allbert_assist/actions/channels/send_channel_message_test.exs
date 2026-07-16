defmodule AllbertAssist.Actions.Channels.SendChannelMessageTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Actions.Channels.SendChannelMessage
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  defmodule PausedChannelPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.paused_channel"

    @impl true
    def display_name, do: "Example Paused Channel"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels do
      [
        %{
          channel_id: "paused_channel",
          provider: "example_paused",
          primitives: [:list],
          threading: :flat,
          trust_class: :server_readable
        }
      ]
    end

    @impl true
    def release_availability do
      [
        %{
          kind: :channel,
          id: "paused_channel",
          release_status: :implemented_not_released,
          live_use_allowed?: false,
          decision: "Synthetic channel is paused for release testing.",
          decision_ref: "test",
          future_features_ref: "test"
        }
      ]
    end
  end

  setup do
    original_plugins = PluginRegistry.registered_plugins()

    PluginRegistry.clear()
    assert {:ok, "example.paused_channel"} = PluginRegistry.register_module(PausedChannelPlugin)

    on_exit(fn ->
      PluginRegistry.clear()
      Enum.each(original_plugins, &PluginRegistry.register_entry/1)
    end)

    :ok
  end

  test "stops explicitly unreleased channel sends before target lookup or dispatch" do
    assert {:ok, response} =
             SendChannelMessage.run(
               %{channel: "paused_channel", target: "not-allowlisted", body: "hi"},
               %{}
             )

    assert response.status == :stopped
    assert response.error == {:implemented_not_released, %{kind: :channel, id: "paused_channel"}}
    assert response.message =~ "implemented but not released"
    refute match?({:target_rejected, _reason}, response.error)
  end
end
