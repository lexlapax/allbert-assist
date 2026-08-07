defmodule AllbertArtifactsWeb.ArtifactLiveReadinessTest do
  use ExUnit.Case, async: true

  test "artifact action context carries the mounted pack epoch" do
    source = File.read!(Path.expand("../../lib/allbert_artifacts_web/artifact_live.ex", __DIR__))

    assert source =~ "allbert_pack_epoch: socket.assigns.allbert_pack_epoch"
  end
end
