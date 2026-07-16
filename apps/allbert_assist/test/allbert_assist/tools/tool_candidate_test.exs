defmodule AllbertAssist.Tools.ToolCandidateTest do
  use ExUnit.Case, async: true
  @moduletag :external_runtime_serial

  alias AllbertAssist.Tools.ToolCandidate

  test "normalizes local candidates as immediately usable" do
    assert {:ok, candidate} =
             ToolCandidate.normalize(%{
               "name" => "Append Memory",
               "description" => "Store a memory entry.",
               "source" => "local_action",
               "usable_now?" => false,
               "requires" => "connect_confirmation",
               "provenance" => %{"registry" => "actions"}
             })

    assert candidate.name == "Append Memory"
    assert candidate.source == :local_action
    assert candidate.usable_now?
    assert candidate.requires == :none
    assert candidate.provenance == %{"registry" => "actions"}
    assert candidate.id =~ "local_action:append-memory:"
  end

  test "normalizes remote MCP candidates as inert until the connect gate" do
    assert {:ok, candidate} =
             ToolCandidate.normalize(%{
               id: "registry.modelcontextprotocol.io/acme/calendar",
               name: "Calendar Server",
               description: "Calendar tools",
               source: :remote_mcp,
               usable_now?: true,
               requires: :none,
               signals: %{registry: "official"}
             })

    assert candidate.id == "registry.modelcontextprotocol.io/acme/calendar"
    assert candidate.source == :remote_mcp
    refute candidate.usable_now?
    assert candidate.requires == :connect_confirmation
    assert candidate.signals == %{registry: "official"}
  end

  test "rejects invalid source values" do
    assert {:error, {:invalid_source, "remote-plugin"}} =
             ToolCandidate.normalize(%{
               name: "Bad Source",
               description: "Invalid",
               source: "remote-plugin"
             })
  end
end
