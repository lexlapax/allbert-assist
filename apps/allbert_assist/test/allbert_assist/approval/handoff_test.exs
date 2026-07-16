defmodule AllbertAssist.Approval.HandoffTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Approval.Handoff

  @handoff %{
    confirmation_id: "conf_123",
    summary: "Delete the draft?"
  }

  test "selects button before typed command and list" do
    assert {:ok, {:button, payload}} =
             Handoff.render(@handoff, %{primitives: [:button, :typed_command, :list]})

    assert payload.text =~ "conf_123"
    assert %{label: "Approve", callback_data: "allbert:v1:approve:conf_123"} in payload.buttons
  end

  test "selects typed command when button is not effective" do
    assert {:ok, {:typed_command, payload}} =
             Handoff.render(@handoff, %{primitives: [:typed_command, :list]})

    assert payload.commands == [
             "ALLBERT:APPROVE:conf_123",
             "ALLBERT:DENY:conf_123",
             "ALLBERT:SHOW:conf_123"
           ]
  end

  test "selects link only when a workspace url is present" do
    assert {:ok, {:list, _payload}} =
             Handoff.render(@handoff, %{primitives: [:link, :list]})

    assert {:ok, {:link, payload}} =
             Handoff.render(
               Map.put(@handoff, :render_hints, %{
                 workspace_url: "http://localhost:4000/workspace"
               }),
               %{primitives: [:link, :list]}
             )

    assert payload.url == "http://localhost:4000/workspace"
  end

  test "selects list fallback" do
    assert {:ok, {:list, payload}} = Handoff.render(@handoff, %{primitives: [:list]})

    assert [%{index: 1, label: "Approve"} | _] = payload.numbered_options
  end

  test "rejects invalid primitive declarations" do
    assert {:error, :invalid_primitives} = Handoff.render(@handoff, %{primitives: [:unknown]})
  end
end
