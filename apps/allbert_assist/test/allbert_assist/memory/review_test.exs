defmodule AllbertAssist.Memory.ReviewTest do
  use ExUnit.Case, async: true
  @moduletag :global_process_serial

  alias AllbertAssist.Memory.Review

  @entry """
  # Memory: Example

  - Timestamp: 2026-05-15T12:00:00Z
  - Category: notes
  - Source signal: sig-1
  - Actor: alice
  - Agent: Agent
  - Channel: cli

  ## Body

  Body text.
  """

  test "parse_review returns unreviewed defaults when the section is absent" do
    assert Review.parse_review(@entry) == %{
             review_status: :unreviewed,
             reviewed_at: nil,
             reviewed_by: nil,
             correction_note: nil
           }
  end

  test "write_review round-trips a review section" do
    assert {:ok, content} =
             Review.write_review(@entry, %{
               status: :kept,
               reviewed_at: "2026-05-15T13:00:00Z",
               reviewed_by: "alice",
               note: "good"
             })

    assert content =~ "## Review"
    assert content =~ "- Status: kept"
    assert content =~ "- Correction note: good"
    assert content =~ "Body text."

    assert Review.parse_review(content) == %{
             review_status: :kept,
             reviewed_at: "2026-05-15T13:00:00Z",
             reviewed_by: "alice",
             correction_note: "good"
           }
  end

  test "write_review rejects unknown statuses" do
    assert {:error, {:invalid_review_status, "archived"}} =
             Review.write_review(@entry, %{status: "archived"})
  end
end
