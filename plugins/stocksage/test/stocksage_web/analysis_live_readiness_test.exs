defmodule StockSageWeb.AnalysisLiveReadinessTest do
  use ExUnit.Case, async: true

  test "every Runner context carries the mounted pack epoch" do
    source = File.read!(Path.expand("../../lib/stocksage_web/analysis_live.ex", __DIR__))

    assert source =~ "allbert_pack_epoch: socket.assigns.allbert_pack_epoch"
    assert source =~ "defp rerun_context(socket)"
    assert source =~ "defp sync_lesson_context(socket)"
  end
end
