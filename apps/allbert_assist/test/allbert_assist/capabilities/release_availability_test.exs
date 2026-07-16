defmodule AllbertAssist.Capabilities.ReleaseAvailabilityTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Capabilities.ReleaseAvailability
  alias AllbertAssist.Plugin.Entry

  test "defaults unknown capabilities to released live use" do
    decision = ReleaseAvailability.decision({:channel, "telegram"}, plugin_entries: [])

    assert decision.release_status == :released
    assert decision.live_use_allowed?
    assert decision.kind == :channel
    assert decision.id == "telegram"
  end

  test "resolves plugin-carried release declarations" do
    plugin = %Entry{
      plugin_id: "example.channel",
      display_name: "Example Channel",
      version: "0.1.0",
      kind: "channel",
      source: :shipped,
      status: :enabled,
      trust_status: :trusted,
      release_availability: [
        %{
          kind: :channel,
          id: "example_channel",
          release_status: :implemented_not_released,
          live_use_allowed?: false,
          decision: "Implemented, but not released for live use.",
          decision_ref: "docs/plans/example.md",
          future_features_ref: "docs/plans/future-features.md"
        }
      ]
    }

    decision =
      ReleaseAvailability.decision({:channel, "example_channel"}, plugin_entries: [plugin])

    assert decision.release_status == :implemented_not_released
    refute decision.live_use_allowed?
    assert ReleaseAvailability.diagnostic({:channel, "example_channel"}, plugin_entries: [plugin])
  end

  test "returns a structured blocked reason for unreleased capabilities" do
    plugin = %Entry{
      plugin_id: "example.channel",
      display_name: "Example Channel",
      version: "0.1.0",
      kind: "channel",
      source: :shipped,
      status: :enabled,
      trust_status: :trusted,
      release_availability: [
        %{
          kind: :channel,
          id: "example_channel",
          release_status: :implemented_not_released,
          live_use_allowed?: false,
          decision: "Implemented, but not released for live use.",
          decision_ref: "docs/plans/example.md",
          future_features_ref: "docs/plans/future-features.md"
        }
      ]
    }

    assert {:error, {:implemented_not_released, decision}} =
             ReleaseAvailability.ensure_live_use_allowed({:channel, "example_channel"},
               plugin_entries: [plugin]
             )

    assert decision.id == "example_channel"
  end

  test "unrelated released channels are not affected by explicit blocked declarations" do
    plugin_entries = [
      %Entry{
        plugin_id: "allbert.whatsapp",
        display_name: "WhatsApp",
        version: "0.53.0",
        kind: "channel",
        source: :shipped,
        status: :enabled,
        trust_status: :trusted,
        release_availability: [
          %{
            kind: :channel,
            id: "whatsapp",
            release_status: :implemented_not_released,
            live_use_allowed?: false,
            decision: "Implemented, but not released for live use.",
            decision_ref: "docs/plans/archives/v0.53-plan.md",
            future_features_ref: "docs/plans/future-features.md"
          }
        ]
      }
    ]

    assert ReleaseAvailability.release_status({:channel, "discord"},
             plugin_entries: plugin_entries
           ) ==
             :released

    assert ReleaseAvailability.release_status({:channel, "slack"}, plugin_entries: plugin_entries) ==
             :released

    refute ReleaseAvailability.live_use_allowed?({:channel, "whatsapp"},
             plugin_entries: plugin_entries
           )
  end
end
