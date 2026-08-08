defmodule AllbertAssist.Actions.Channels.SendChannelMessageTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Actions.Channels.SendChannelMessage

  test "stops explicitly unreleased channel sends before target lookup or dispatch" do
    assert {:ok, response} =
             SendChannelMessage.run(
               %{channel: "signal", target: "not-allowlisted", body: "hi"},
               %{}
             )

    assert response.status == :stopped
    assert response.error == {:implemented_not_released, %{kind: :channel, id: "signal"}}
    assert response.message =~ "implemented but not released"
    refute match?({:target_rejected, _reason}, response.error)
  end
end
