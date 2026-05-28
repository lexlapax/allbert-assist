defmodule Mix.Tasks.Allbert.OnboardTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Allbert.Onboard, as: OnboardTask

  setup do
    previous_halt = Application.get_env(:allbert_assist, Mix.Tasks.Allbert.Onboard)

    Application.put_env(:allbert_assist, Mix.Tasks.Allbert.Onboard,
      halt_fun: fn code -> throw({:halt, code}) end
    )

    on_exit(fn ->
      Mix.Task.reenable("allbert.onboard")

      if previous_halt do
        Application.put_env(:allbert_assist, Mix.Tasks.Allbert.Onboard, previous_halt)
      else
        Application.delete_env(:allbert_assist, Mix.Tasks.Allbert.Onboard)
      end
    end)
  end

  test "frames and resumes onboarding objective" do
    first_output =
      capture_io(fn ->
        assert :ok = OnboardTask.run(["--user", "alice"])
      end)

    assert first_output =~ "Onboarding objective:"
    assert first_output =~ "Current step: 1. Welcome + scope"
    assert first_output =~ "Run doctor"
    assert first_output =~ "action=doctor_model_profile"

    Mix.Task.reenable("allbert.onboard")

    second_output =
      capture_io(fn ->
        assert :ok = OnboardTask.run(["--user", "alice"])
      end)

    first_id =
      first_output
      |> String.split("Onboarding objective: ")
      |> Enum.at(1)
      |> String.split()
      |> hd()

    second_id =
      second_output
      |> String.split("Onboarding objective: ")
      |> Enum.at(1)
      |> String.split()
      |> hd()

    assert second_id == first_id
  end

  test "operator alias must match user" do
    assert {:halt, 66} =
             catch_throw(
               capture_io(:stderr, fn ->
                 OnboardTask.run(["--user", "alice", "--operator", "bob"])
               end)
             )
  end
end
