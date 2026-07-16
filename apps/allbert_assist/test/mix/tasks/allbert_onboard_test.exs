defmodule Mix.Tasks.Allbert.OnboardTest do
  @moduledoc """
  v0.63 M7.3 — `mix allbert.onboard` is re-pointed at the shared wizard machine (the
  dev mirror of `allbert onboard`); the legacy objective flow is retired.
  """
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.CLI.FirstRun
  alias Mix.Tasks.Allbert.Onboard, as: OnboardTask

  setup do
    previous_halt = Application.get_env(:allbert_assist, Mix.Tasks.Allbert.Onboard)
    original_home = System.get_env("ALLBERT_HOME")

    home =
      Path.join(System.tmp_dir!(), "allbert-onboard-task-#{System.unique_integer([:positive])}")

    System.put_env("ALLBERT_HOME", home)

    Application.put_env(:allbert_assist, Mix.Tasks.Allbert.Onboard,
      halt_fun: fn code -> throw({:halt, code}) end
    )

    on_exit(fn ->
      Mix.Task.reenable("allbert.onboard")
      File.rm_rf!(home)

      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      if previous_halt do
        Application.put_env(:allbert_assist, Mix.Tasks.Allbert.Onboard, previous_halt)
      else
        Application.delete_env(:allbert_assist, Mix.Tasks.Allbert.Onboard)
      end
    end)

    :ok
  end

  test "starts a track and reports the wizard state" do
    output = capture_io(fn -> assert :ok = OnboardTask.run(["--quickstart"]) end)
    assert output =~ "track: quickstart"
    assert output =~ "Step: welcome"

    Mix.Task.reenable("allbert.onboard")
    status = capture_io(fn -> assert :ok = OnboardTask.run(["status"]) end)
    assert status =~ "onboard status="
    assert status =~ "track=quickstart"
  end

  test "advances a step through the wizard machine" do
    capture_io(fn -> OnboardTask.run(["--quickstart"]) end)
    Mix.Task.reenable("allbert.onboard")

    output = capture_io(fn -> assert :ok = OnboardTask.run(["advance", "welcome"]) end)
    assert output =~ "Recorded welcome."
    assert FirstRun.read_marker()["wizard_done"] == ["welcome"]
  end

  test "confirmed --reset clears the marker" do
    capture_io(fn -> OnboardTask.run(["--quickstart"]) end)
    Mix.Task.reenable("allbert.onboard")

    output = capture_io(fn -> assert :ok = OnboardTask.run(["--reset", "--yes"]) end)
    assert output =~ "reset"
    assert FirstRun.read_marker() == %{}
  end

  test "an unknown flag exits non-zero" do
    output =
      capture_io(fn ->
        assert catch_throw(OnboardTask.run(["--nope"])) == {:halt, 2}
      end)

    assert output =~ "Unknown flag"
  end
end
