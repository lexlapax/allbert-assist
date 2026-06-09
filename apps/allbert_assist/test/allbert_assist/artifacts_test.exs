defmodule AllbertAssist.ArtifactsTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Artifacts

  test "list rejects invalid since filters before reading the index" do
    assert {:error, {:invalid_since, "not-a-date"}} = Artifacts.list(since: "not-a-date")
  end
end
