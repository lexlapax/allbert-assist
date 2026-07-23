defmodule AllbertAssist.Jobs.ScheduleTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Jobs.Schedule

  describe "normalize/1" do
    test "normalizes supported schedule shapes" do
      assert {:ok, %{"kind" => "manual"}} = Schedule.normalize(%{kind: :manual})

      assert {:ok, %{"kind" => "daily", "at" => "08:05"}} =
               Schedule.normalize(%{kind: "daily", at: "8:05"})

      assert {:ok, %{"kind" => "weekly", "weekday" => "monday", "at" => "09:00"}} =
               Schedule.normalize(%{
                 "kind" => "weekly",
                 "weekday" => "Monday",
                 "at" => "09:00"
               })

      assert {:ok, %{"kind" => "cron", "expression" => "0 8 * * 1-5"}} =
               Schedule.normalize(%{"kind" => "cron", "expression" => "0 8 * * 1-5"})
    end

    test "rejects invalid times and unsupported cron syntax" do
      assert {:error, {:invalid_time, "25:00"}} =
               Schedule.normalize(%{"kind" => "daily", "at" => "25:00"})

      assert {:error, {:unsupported_cron_syntax, "*/5"}} =
               Schedule.normalize(%{"kind" => "cron", "expression" => "*/5 * * * *"})
    end
  end

  describe "next_due/3" do
    test "manual schedules have no due time" do
      assert {:ok, nil} =
               Schedule.next_due(%{"kind" => "manual"}, "UTC", ~U[2026-05-14 07:00:00Z])
    end

    test "daily schedules return the next wall-clock time in UTC" do
      assert {:ok, ~U[2026-05-14 08:00:00Z]} =
               Schedule.next_due(
                 %{"kind" => "daily", "at" => "08:00"},
                 "UTC",
                 ~U[2026-05-14 07:59:00Z]
               )

      assert {:ok, ~U[2026-05-15 08:00:00Z]} =
               Schedule.next_due(
                 %{"kind" => "daily", "at" => "08:00"},
                 "UTC",
                 ~U[2026-05-14 08:00:00Z]
               )
    end

    test "weekly schedules return the next matching weekday" do
      assert {:ok, ~U[2026-05-18 08:00:00Z]} =
               Schedule.next_due(
                 %{"kind" => "weekly", "weekday" => "monday", "at" => "08:00"},
                 "UTC",
                 ~U[2026-05-14 12:00:00Z]
               )
    end

    test "cron schedules use five-field minute granularity" do
      assert {:ok, ~U[2026-05-14 08:00:00Z]} =
               Schedule.next_due(
                 %{"kind" => "cron", "expression" => "0 8 * * 1-5"},
                 "UTC",
                 ~U[2026-05-14 07:59:00Z]
               )

      assert {:ok, ~U[2026-05-15 08:00:00Z]} =
               Schedule.next_due(
                 %{"kind" => "cron", "expression" => "0 8 * * 1-5"},
                 "UTC",
                 ~U[2026-05-14 08:00:00Z]
               )
    end

    test "cron schedules can cross midnight" do
      assert {:ok, ~U[2026-05-15 00:00:00Z]} =
               Schedule.next_due(
                 %{"kind" => "cron", "expression" => "0 0 * * *"},
                 "UTC",
                 ~U[2026-05-14 23:59:00Z]
               )
    end

    test "named IANA time zones are accepted" do
      assert {:ok, due} =
               Schedule.next_due(
                 %{"kind" => "daily", "at" => "08:00"},
                 "America/Los_Angeles",
                 ~U[2026-05-14 14:00:00Z]
               )

      assert DateTime.to_iso8601(due) == "2026-05-14T15:00:00Z"
    end

    test "daily schedules advance through a daylight-saving spring gap" do
      assert {:ok, ~U[2026-03-08 10:00:00Z]} =
               Schedule.next_due(
                 %{"kind" => "daily", "at" => "02:30"},
                 "America/Los_Angeles",
                 ~U[2026-03-08 07:00:00Z]
               )
    end

    test "daily schedules choose the first occurrence of an ambiguous fall time" do
      assert {:ok, ~U[2026-11-01 08:30:00Z]} =
               Schedule.next_due(
                 %{"kind" => "daily", "at" => "01:30"},
                 "America/Los_Angeles",
                 ~U[2026-11-01 07:00:00Z]
               )
    end
  end

  describe "validate_timezone/1" do
    test "accepts IANA names and rejects unknown zones" do
      assert :ok = Schedule.validate_timezone("America/Los_Angeles")

      assert {:error, {:invalid_timezone, _reason}} =
               Schedule.validate_timezone("America/Definitely_Not_A_Zone")
    end
  end
end
