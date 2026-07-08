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

  describe "v0.63 M6 non-interactive contract" do
    test "refuses a fresh non-interactive run with no explicit track" do
      # Guarantee an un-started wizard regardless of test order (shared Home state).
      FirstRun.reset_onboarding()
      assert {msg, code} = Area.dispatch(["--non-interactive"])
      assert code != 0
      assert msg =~ "requires an explicit track"
    end

    test "apply-persona without authorization refuses (never prompts)" do
      assert {msg, code} = Area.dispatch(["apply-persona", "developer"])
      assert code != 0
      assert msg =~ "confirmation-gated"
      assert msg =~ "--authorize"
    end

    test "apply-persona with no id errors" do
      assert {msg, code} = Area.dispatch(["apply-persona"])
      assert code != 0
      assert msg =~ "persona id"
    end
  end

  describe "v0.63 M6 --authorize pre-authorization" do
    @describetag :external_runtime_serial

    setup do
      alias AllbertAssist.Settings

      original_settings = Application.get_env(:allbert_assist, Settings)

      root =
        Path.join(System.tmp_dir!(), "allbert-onboard-auth-#{System.unique_integer([:positive])}")

      Application.put_env(:allbert_assist, Settings, root: root)

      on_exit(fn ->
        if original_settings,
          do: Application.put_env(:allbert_assist, Settings, original_settings),
          else: Application.delete_env(:allbert_assist, Settings)

        File.rm_rf!(root)
      end)

      {:ok,
       context: %{actor: "local", channel: :cli, request: %{operator_id: "local", channel: :cli}}}
    end

    test "--authorize records + approves a durable confirmation and applies the persona",
         %{context: context} do
      assert {msg, 0} = Area.dispatch(["apply-persona", "developer", "--authorize"], context)
      assert msg =~ "Authorized and applied"
      assert msg =~ "confirmation"

      # The pinned developer seeds are now live — proof the gated action really ran.
      assert AllbertAssist.Settings.get("coding.default_approval_mode") == {:ok, "plan"}
    end

    test "--accept-risk warns but routes to the same durable approval path",
         %{context: context} do
      assert {msg, 0} = Area.dispatch(["apply-persona", "general", "--accept-risk"], context)
      assert msg =~ "deprecated"
      assert msg =~ "Authorized and applied"
    end
  end
end
