defmodule AllbertAssist.CLI.Areas.OnboardingTest do
  @moduledoc "v0.63 M1 — the `allbert onboard` area dispatcher (flags + reset guard)."
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.CLI.Areas.Onboarding, as: Area
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.SecurityFixtures.AssertBinding
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments

  setup do
    original = System.get_env("ALLBERT_HOME")

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-onboard-area-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(home)
    System.put_env("ALLBERT_HOME", home)

    # v1.3 M9.b.12.d — this file previously set only ALLBERT_HOME, so it
    # inherited whatever Settings root another file had put in app env. That
    # made the wizard rows depend on ambient provider state: the same row
    # reported the DirectAnswer route unavailable, the starter model missing, or
    # the model ready, purely by what ran before it. Own the root and the
    # resolved-settings cache here, so every row in this file starts from the
    # shipped defaults.
    original_settings = Application.get_env(:allbert_assist, Settings)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Fragments.clear_cache()

    on_exit(fn ->
      if original_settings,
        do: Application.put_env(:allbert_assist, Settings, original_settings),
        else: Application.delete_env(:allbert_assist, Settings)

      Fragments.clear_cache()
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

  test "a canonical step opens directly and an unknown step is rejected" do
    Area.dispatch(["--quickstart"])
    assert {out, 0} = Area.dispatch(["optional_connect"])
    assert out =~ "Opened optional_connect."
    assert out =~ "Step: optional_connect"

    assert {out, 1} = Area.dispatch(["not-a-step"])
    assert out =~ "Unknown step"
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

    # `--reset` is scoped to onboarding: reset_onboarding/0 drops the onboarding
    # keys and deliberately preserves any other namespace sharing the marker
    # file. Asserting `== %{}` only held while onboarding was the sole writer;
    # M9.b.3 added "model_disclosure" alongside it. Preserving that is correct,
    # not a leak — Disclosure re-pends on every surface whenever the route set
    # changes (disclosure.ex "any route-set change becomes pending"), so consent
    # is bound to the routes rather than to onboarding state. Assert the
    # contract that actually holds.
    marker = FirstRun.read_marker()

    for key <- ~w(onboarding_complete profile_reviewed wizard_started track
                  wizard_step wizard_done wizard_direct_entry applied_persona) do
      refute Map.has_key?(marker, key), "--reset must clear the onboarding key #{key}"
    end

    assert Map.keys(marker) -- ["model_disclosure"] == [],
           "--reset must leave nothing behind but non-onboarding namespaces"
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
      original_override = Application.get_env(:allbert_assist, :first_model_state_override)
      Application.put_env(:allbert_assist, :first_model_state_override, :local_ready)

      on_exit(fn ->
        if original_override,
          do:
            Application.put_env(
              :allbert_assist,
              :first_model_state_override,
              original_override
            ),
          else: Application.delete_env(:allbert_assist, :first_model_state_override)
      end)

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

    test "model_path shows local repair before provider key entry" do
      FirstRun.reset_onboarding()
      original_override = Application.get_env(:allbert_assist, :first_model_state_override)

      on_exit(fn ->
        if original_override,
          do:
            Application.put_env(:allbert_assist, :first_model_state_override, original_override),
          else: Application.delete_env(:allbert_assist, :first_model_state_override)
      end)

      Application.put_env(:allbert_assist, :first_model_state_override, :model_missing)

      # v1.3 M9.b.12.d — :first_model_state_override only substitutes the *global
      # starter model* probe. M9.b.3 qualified DirectAnswer routing per task, and
      # that path reaches ModelDoctor, which probes the endpoint configured in
      # settings — a live localhost Ollama. On a developer machine running Ollama
      # with a model matching `direct_answer_local` the doctor returns
      # model_available: true, so DirectAnswer readiness was genuinely :ready and
      # this row failed on that machine while passing on CI. Pin the local
      # endpoint unreachable so ":model_missing" holds for the task model too.
      assert {:ok, _} =
               Settings.put(
                 "providers.local_ollama.base_url",
                 "http://127.0.0.1:1/v1",
                 AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
               )

      {io, out} = scripted_io(["q", "", "", "", :quit])

      assert {"", 0} = Area.run_interactive(nil, io)
      text = output(out)

      assert text =~ "The runtime is up, but the starter model isn't downloaded."
      assert text =~ "Next: Pull the starter model"
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

    test "model repair subcommands require authorization and preview before apply" do
      assert {install_msg, install_code} = Area.dispatch(["install-runtime"])
      assert install_code != 0
      assert install_msg =~ "confirmation-gated"
      assert install_msg =~ "--authorize"

      assert {install_preview, 0} = Area.dispatch(["install-runtime", "--authorize"])
      assert install_preview =~ "Would run"
      assert install_preview =~ "--authorize --yes"
      refute install_preview =~ "ollama pull"

      assert {msg, code} = Area.dispatch(["pull-model"])
      assert code != 0
      assert msg =~ "confirmation-gated"
      assert msg =~ "--authorize"

      assert {preview, 0} = Area.dispatch(["pull-model", "--authorize"])
      assert preview =~ "Would pull"
      assert preview =~ "--authorize --yes"
      refute preview =~ "ollama pull"

      AssertBinding.check!("first-model-guided-runtime-install-no-cli-001", [
        :install_runtime_requires_authorization,
        :dry_run_preview_before_apply,
        :no_manual_ollama_cli_instruction
      ])
    end
  end

  describe "v0.63 M6 --authorize pre-authorization" do
    @describetag :external_runtime_serial

    setup do
      alias AllbertAssist.Settings

      original_settings = Application.get_env(:allbert_assist, Settings)

      root =
        Path.join(
          System.tmp_dir!(),
          "allbert-onboard-auth-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      File.rm_rf!(root)
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
