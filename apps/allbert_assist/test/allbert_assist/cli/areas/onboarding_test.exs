defmodule AllbertAssist.CLI.Areas.OnboardingTest do
  @moduledoc "v0.63 M1 — the `allbert onboard` area dispatcher (flags + reset guard)."
  use ExUnit.Case, async: false

  alias AllbertAssist.CLI.Areas.Onboarding, as: Area
  alias AllbertAssist.CLI.FirstRun

  setup do
    original = System.get_env("ALLBERT_HOME")

    home =
      Path.join(System.tmp_dir!(), "allbert-onboard-area-#{System.unique_integer([:positive])}")

    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)

      if original,
        do: System.put_env("ALLBERT_HOME", original),
        else: System.delete_env("ALLBERT_HOME")
    end)

    :ok
  end

  test "--quickstart / --advanced start the wizard on the chosen track" do
    assert {out, 0} = Area.dispatch(["--quickstart"])
    assert out =~ "track: quickstart"
    assert out =~ "Step: welcome"

    assert {out, 0} = Area.dispatch(["--advanced"])
    assert out =~ "track: advanced"
  end

  test "status renders one operator-language line, never a raw probe atom" do
    Area.dispatch(["--quickstart"])
    assert {line, 0} = Area.dispatch(["status"])
    assert line =~ "onboard status="
    assert line =~ "readiness="
    refute line =~ ":local_ready"
    refute line =~ "runtime_missing"
  end

  test "--reset requires explicit --yes (confirmation), then clears the marker" do
    Area.dispatch(["--quickstart"])
    FirstRun.mark_profile_reviewed()

    # Without --yes: refuses and changes nothing.
    assert {msg, 1} = Area.dispatch(["--reset"])
    assert msg =~ "--reset --yes"
    assert FirstRun.read_marker()["profile_reviewed"] == true

    # With --yes: resets.
    assert {msg, 0} = Area.dispatch(["--reset", "--yes"])
    assert msg =~ "reset"
    assert FirstRun.read_marker() == %{}
  end

  test "unknown flags render usage with exit code 2" do
    assert {_out, 2} = Area.dispatch(["--nope"])
  end
end
