defmodule AllbertAssist.Memory.ReviewCadenceSyncTest do
  @moduledoc """
  v1.3 M9.b.13.a — `memory.review_cadence` applied to the one managed rebuild job.

  This module had no direct coverage. It is the only writer of that job's
  schedule and pause state, and M9.b.10 made the same job the thing that
  bootstraps the Memory projection on a fresh Home — so a cadence bug now
  reaches further than review timing. A `manual` cadence in particular must
  leave the job paused, which is exactly the state the M9.b.10 bootstrap and the
  M9.b.11 repair kick have to work against.
  """

  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Jobs
  alias AllbertAssist.Memory.ReviewCadence

  @identity "memory-index-rebuild"

  defp managed_job do
    "local"
    |> Jobs.list_jobs(limit: 100)
    |> Enum.find(&(&1.name == @identity))
  end

  test "an unsupported cadence is refused by name rather than silently ignored" do
    assert {:error, {:unsupported_memory_review_cadence, "hourly"}} = ReviewCadence.sync("hourly")
    assert {:error, {:unsupported_memory_review_cadence, nil}} = ReviewCadence.sync(nil)
    assert {:error, {:unsupported_memory_review_cadence, :daily}} = ReviewCadence.sync(:daily)
  end

  test "daily sets a daily schedule and leaves the job active" do
    assert {:ok, result} = ReviewCadence.sync("daily")
    assert result.cadence == "daily"
    assert result.source == :memory_review_cadence

    job = managed_job()
    assert job.id == result.job_id
    assert job.status == "active"
    assert job.schedule["kind"] == "daily"
    assert job.metadata["cadence"] == "daily"
  end

  test "weekly sets a weekly schedule and leaves the job active" do
    assert {:ok, result} = ReviewCadence.sync("weekly")
    assert result.cadence == "weekly"

    job = managed_job()
    assert job.status == "active"
    assert job.schedule["kind"] == "weekly"
    assert job.schedule["weekday"] == "sunday"
  end

  test "manual pauses the job and reports the pause" do
    assert {:ok, _active} = ReviewCadence.sync("daily")
    assert managed_job().status == "active"

    assert {:ok, result} = ReviewCadence.sync("manual")
    assert result.action == :paused

    job = managed_job()
    assert job.status == "paused"
    assert job.schedule["kind"] == "manual"
  end

  test "moving off manual resumes the same job rather than creating another" do
    assert {:ok, paused} = ReviewCadence.sync("manual")
    assert managed_job().status == "paused"

    assert {:ok, resumed} = ReviewCadence.sync("weekly")

    assert resumed.job_id == paused.job_id,
           "the managed row must be adopted, not recreated; a new id orphans its run history"

    assert managed_job().status == "active"
  end

  test "repeating a cadence is idempotent on the same row" do
    assert {:ok, first} = ReviewCadence.sync("daily")
    assert {:ok, second} = ReviewCadence.sync("daily")
    assert first.job_id == second.job_id
    assert length(Enum.filter(Jobs.list_jobs("local", limit: 100), &(&1.name == @identity))) == 1
  end
end
