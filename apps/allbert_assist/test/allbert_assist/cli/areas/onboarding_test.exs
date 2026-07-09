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

  test "M8.4: bare `allbert onboard` (no flags) resumes without raising on a fresh marker" do
    # Regression: opts[:non_interactive] is nil when the flag is absent, and a raw nil on
    # the left of strict `and` raised on every bare invocation. Force the non-TTY line
    # path (default) so this deterministically reaches render_state rather than the loop.
    FirstRun.reset_onboarding()
    Application.put_env(:allbert_assist, :onboard_force_tty, false)
    assert {out, 0} = Area.dispatch([])
    assert is_binary(out)
  after
    Application.delete_env(:allbert_assist, :onboard_force_tty)
  end

  describe "v0.63 M7.5 interactive TTY wizard" do
    defp scripted_io(gets_script, mask \\ "") do
      {:ok, out} = Agent.start_link(fn -> [] end)
      {:ok, queue} = Agent.start_link(fn -> gets_script end)

      io = %{
        puts: fn line -> Agent.update(out, &[to_string(line) | &1]) end,
        gets: fn _prompt ->
          Agent.get_and_update(queue, fn
            [h | t] -> {h, t}
            [] -> {:quit, []}
          end)
        end,
        mask_gets: fn _prompt -> mask end
      }

      {io, out}
    end

    defp output(out), do: out |> Agent.get(&Enum.reverse/1) |> Enum.join("\n")

    test "drives the same canonical step IDs to completion, no fork" do
      FirstRun.reset_onboarding()
      # Track chooser "q" then Enter for each step.
      {io, out} = scripted_io(["q" | List.duplicate("", 10)])

      assert {"", 0} = Area.run_interactive(nil, io)
      text = output(out)

      for step <- ~w(welcome track_select model_path profile_select profile_review
                     health_check first_chat) do
        assert text =~ step
      end

      assert text =~ "Onboarding complete."
    end

    test "masked provider entry never echoes the secret" do
      FirstRun.reset_onboarding()
      {io, out} = scripted_io(["q" | List.duplicate("", 10)], "sk-interactive-secret")

      assert {"", 0} = Area.run_interactive(nil, io)
      text = output(out)

      assert text =~ "Stored (masked)."
      refute text =~ "sk-interactive-secret"
    end

    test "quitting pauses without completing" do
      FirstRun.reset_onboarding()
      {io, out} = scripted_io(["q", :quit])

      assert {"", 0} = Area.run_interactive(nil, io)
      text = output(out)

      assert text =~ "Paused. Resume with `allbert onboard`."
      refute text =~ "Onboarding complete."
    end
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

    test "--authorize on a non-persona subcommand warns instead of silently ignoring" do
      Area.dispatch(["--quickstart"])
      assert {msg, _code} = Area.dispatch(["status", "--authorize"])
      assert msg =~ "no effect here"

      assert {msg2, _} = Area.dispatch(["advance", "welcome", "--accept-risk"])
      assert msg2 =~ "no effect here"
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

    test "M7.4: --authorize (no --yes) shows the review diff and writes nothing",
         %{context: context} do
      before = AllbertAssist.Settings.get("coding.default_approval_mode")

      assert {msg, 0} = Area.dispatch(["apply-persona", "developer", "--authorize"], context)
      assert msg =~ "Review — developer"
      # M7.9: the header states changed-of-total so the count and the full listing agree.
      assert msg =~ "seeded key(s) change"
      assert msg =~ "coding.default_approval_mode"
      assert msg =~ "--authorize --yes"

      # Nothing was written by the review.
      assert AllbertAssist.Settings.get("coding.default_approval_mode") == before
    end

    test "M7.4: --authorize --yes applies through the durable path and records the persona",
         %{context: context} do
      assert {msg, 0} =
               Area.dispatch(["apply-persona", "developer", "--authorize", "--yes"], context)

      assert msg =~ "Authorized and applied"

      assert AllbertAssist.Settings.get("coding.default_approval_mode") == {:ok, "plan"}
      assert FirstRun.read_marker()["applied_persona"] == "developer"
    end

    test "--accept-risk --yes warns but routes to the same durable approval path",
         %{context: context} do
      assert {msg, 0} =
               Area.dispatch(["apply-persona", "general", "--accept-risk", "--yes"], context)

      assert msg =~ "deprecated"
      assert msg =~ "Authorized and applied"
    end
  end
end
