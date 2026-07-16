defmodule AllbertAssistWeb.WorkspaceOnboardingTest do
  use AllbertAssistWeb.ConnCase, async: false
  use AllbertAssistWeb.WorkspaceLiveCase

  import Phoenix.LiveViewTest

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Paths

  @runtime_async_timeout 60_000

  describe "v0.63 M5 guided wizard panel" do
    @describetag :onboarding_wizard

    setup do
      # Snapshot + restore the Home onboarding marker so wizard mutations in these
      # tests never leak into the seeded (already-onboarded) suite baseline.
      saved = FirstRun.read_marker()

      on_exit(fn ->
        FirstRun.reset_onboarding()
        if saved != %{}, do: FirstRun.merge_marker(saved)
      end)

      :ok
    end

    test "renders the shared M1 wizard with an operator readiness label", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")

      assert has_element?(view, "#workspace-onboarding-wizard")

      # The readiness badge shows an operator label, never a raw probe/readiness atom.
      readiness_html =
        view |> element("#workspace-onboarding-readiness") |> render()

      assert readiness_html =~ ~r/Ready|Needs (model|runtime|review|credentials)/

      # No raw first-model *probe* atom may appear (the mapped readiness label may ride
      # in the `data-readiness` machine attribute — that is a test/CSS hook, not operator
      # text, per the Readiness Label Mapping Contract's "atoms for traces/tests only").
      for atom <- ~w(local_ready byok_ready runtime_missing runtime_unhealthy
                     model_missing below_hardware_floor) do
        refute readiness_html =~ atom
      end
    end

    test "starts a track and advances the canonical steps through M1", %{conn: conn} do
      FirstRun.reset_onboarding()
      {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")

      view |> element("#workspace-onboarding-start-quickstart") |> render_click()

      assert has_element?(view, "#workspace-wizard-step-welcome[data-current='true']")

      view |> element("#workspace-wizard-advance-welcome") |> render_click()

      assert has_element?(view, "#workspace-wizard-step-welcome[data-done='true']")
      assert has_element?(view, "#workspace-wizard-step-track_select[data-current='true']")
    end

    test "v1.0 R2: a done step is clickable and rewinds the wizard", %{conn: conn} do
      FirstRun.reset_onboarding()
      {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")

      view |> element("#workspace-onboarding-start-quickstart") |> render_click()
      view |> element("#workspace-wizard-advance-welcome") |> render_click()
      view |> element("#workspace-wizard-advance-track_select") |> render_click()

      assert has_element?(view, "#workspace-wizard-step-model_path[data-current='true']")
      assert has_element?(view, "#workspace-wizard-rewind-welcome")

      html = view |> element("#workspace-wizard-rewind-welcome") |> render_click()

      assert html =~ "Returned to Welcome."
      assert has_element?(view, "#workspace-wizard-step-welcome[data-current='true']")
      refute has_element?(view, "#workspace-wizard-step-track_select[data-done='true']")
      refute has_element?(view, "#workspace-wizard-rewind-welcome")
    end

    test "v1.0 R12: one first-run entry point — the hero leads to guided setup until onboarding completes",
         %{conn: conn} do
      FirstRun.reset_onboarding()
      {:ok, view, _html} = live(conn, ~p"/workspace")

      assert has_element?(view, "#workspace-suggested-action-guided-setup")
      refute has_element?(view, "#workspace-suggested-action-first-model")

      FirstRun.merge_marker(%{"onboarding_complete" => true})
      {:ok, view, _html} = live(conn, ~p"/workspace")

      assert has_element?(view, "#workspace-suggested-action-first-model")
      refute has_element?(view, "#workspace-suggested-action-guided-setup")
    end

    test "v1.0 R11: an explicit go-signal appears once first chat is ready", %{conn: conn} do
      FirstRun.reset_onboarding()
      original = Application.get_env(:allbert_assist, :first_model_state_override)
      Application.put_env(:allbert_assist, :first_model_state_override, :local_ready)

      on_exit(fn ->
        if original,
          do: Application.put_env(:allbert_assist, :first_model_state_override, original),
          else: Application.delete_env(:allbert_assist, :first_model_state_override)
      end)

      {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")

      view |> element("#workspace-onboarding-start-quickstart") |> render_click()
      refute has_element?(view, "#workspace-onboarding-first-chat-ready")

      view |> element("#workspace-wizard-advance-welcome") |> render_click()
      view |> element("#workspace-wizard-advance-track_select") |> render_click()
      view |> element("#workspace-wizard-advance-model_path") |> render_click()

      assert has_element?(view, "#workspace-onboarding-first-chat-ready")
      ready_html = view |> element("#workspace-onboarding-first-chat-ready") |> render()
      assert ready_html =~ "You&#39;re ready to chat."
    end

    test "v1.0 R3: the trust block shows step guidance and changes with the step", %{conn: conn} do
      FirstRun.reset_onboarding()
      {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")

      # Not started yet: no step guidance, the full spine renders.
      spine_html = view |> element("#workspace-onboarding-trust-spine") |> render()
      refute spine_html =~ "workspace-onboarding-step-guidance"
      assert spine_html =~ "Memory review:"
      assert spine_html =~ "Secrets:"

      view |> element("#workspace-onboarding-start-quickstart") |> render_click()

      welcome_html = view |> element("#workspace-onboarding-trust-spine") |> render()
      assert welcome_html =~ "workspace-onboarding-step-guidance"
      assert welcome_html =~ "Confirmation:"
      assert welcome_html =~ "Permission:"
      refute welcome_html =~ "Traces:"

      view |> element("#workspace-wizard-advance-welcome") |> render_click()

      track_html = view |> element("#workspace-onboarding-trust-spine") |> render()
      assert track_html =~ "Local-first:"
      refute track_html =~ "Confirmation:"
      refute track_html == welcome_html
    end

    test "M7.3: the wizard drives real M3/M4 controls and has no legacy objective panel",
         %{conn: conn} do
      FirstRun.reset_onboarding()
      original_override = Application.get_env(:allbert_assist, :first_model_state_override)

      on_exit(fn ->
        if original_override,
          do:
            Application.put_env(:allbert_assist, :first_model_state_override, original_override),
          else: Application.delete_env(:allbert_assist, :first_model_state_override)
      end)

      Application.put_env(:allbert_assist, :first_model_state_override, :runtime_missing)
      {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")

      # The retired legacy objective panel is gone.
      refute has_element?(view, "#onboarding-step-welcome_scope")

      view |> element("#workspace-onboarding-start-quickstart") |> render_click()
      view |> element("#workspace-wizard-advance-welcome") |> render_click()
      view |> element("#workspace-wizard-advance-track_select") |> render_click()

      # model_path renders real M3 masked entry + provider switch/doctor.
      assert has_element?(view, "#workspace-model-install-runtime")
      assert has_element?(view, "#workspace-provider-key[type='password']")
      assert has_element?(view, "#workspace-provider-doctor")

      # profile_select renders persona choices; selecting one computes the review diff.
      view |> element("#workspace-wizard-advance-model_path") |> render_click()
      assert has_element?(view, "#workspace-persona-developer")
      view |> element("#workspace-persona-developer") |> render_click()

      # profile_review shows the M4 current→proposed diff (nothing written yet).
      view |> element("#workspace-wizard-advance-profile_select") |> render_click()
      assert has_element?(view, "#workspace-persona-review-diff")
    end

    test "M7.4: the first_chat step renders starter prompts", %{conn: conn} do
      FirstRun.reset_onboarding()
      {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")

      view |> element("#workspace-onboarding-start-quickstart") |> render_click()

      # Advance QuickStart to the first_chat step.
      for step <- ~w(welcome track_select model_path profile_select profile_review health_check) do
        view |> element("#workspace-wizard-advance-#{step}") |> render_click()
      end

      html = view |> element("#workspace-wizard-first-chat") |> render()
      assert html =~ "Try a first chat"
    end

    test "v0.64: completed onboarding with missing model opens standalone repair panel",
         %{conn: conn} do
      provider_env_keys =
        ~w(ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY GEMINI_API_KEY)

      saved_provider_env = Map.new(provider_env_keys, &{&1, System.get_env(&1)})
      saved_ollama_host = System.get_env("OLLAMA_HOST")
      saved_override = Application.get_env(:allbert_assist, :first_model_state_override)

      on_exit(fn ->
        Enum.each(saved_provider_env, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)

        if saved_ollama_host,
          do: System.put_env("OLLAMA_HOST", saved_ollama_host),
          else: System.delete_env("OLLAMA_HOST")

        if saved_override,
          do: Application.put_env(:allbert_assist, :first_model_state_override, saved_override),
          else: Application.delete_env(:allbert_assist, :first_model_state_override)
      end)

      Enum.each(provider_env_keys, &System.delete_env/1)
      System.put_env("OLLAMA_HOST", "https://example.invalid")

      # v1.0.2 M1 residue (a): `CLI.FirstRun.detect/0`'s first gate is
      # `home_initialized?` = Home dir present AND `<home>/db/allbert.sqlite3`
      # present. The per-test tmp home has neither, so solo runs detect
      # `:home_missing` and the repair destination never resolves. Own the
      # Home marker alongside the onboarding markers below (the file-level
      # setup already owns the Paths env and removes the root in on_exit).
      home = Paths.home()
      File.mkdir_p!(Path.join(home, "db"))
      File.touch!(Path.join([home, "db", "allbert.sqlite3"]))

      FirstRun.reset_onboarding()
      FirstRun.mark_onboarding_complete()
      FirstRun.mark_profile_reviewed()
      Application.put_env(:allbert_assist, :first_model_state_override, :model_missing)

      {:ok, view, _html} = live(conn, ~p"/workspace")

      assert has_element?(view, "#workspace-models-panel")
      assert has_element?(view, "#workspace-model-repair")
      assert has_element?(view, "#workspace-models-pull-model")
      refute has_element?(view, "#workspace-onboarding-wizard")
    end

    test "v0.64.3: model pull dispatches asynchronously and streams live progress frames",
         %{conn: conn} do
      provider_env_keys =
        ~w(ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY GEMINI_API_KEY)

      saved_provider_env = Map.new(provider_env_keys, &{&1, System.get_env(&1)})
      saved_ollama_host = System.get_env("OLLAMA_HOST")
      saved_override = Application.get_env(:allbert_assist, :first_model_state_override)
      saved_puller = Application.get_env(:allbert_assist, :first_model_pull)
      test_pid = self()

      on_exit(fn ->
        Enum.each(saved_provider_env, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)

        if saved_ollama_host,
          do: System.put_env("OLLAMA_HOST", saved_ollama_host),
          else: System.delete_env("OLLAMA_HOST")

        if saved_override,
          do: Application.put_env(:allbert_assist, :first_model_state_override, saved_override),
          else: Application.delete_env(:allbert_assist, :first_model_state_override)

        if saved_puller,
          do: Application.put_env(:allbert_assist, :first_model_pull, saved_puller),
          else: Application.delete_env(:allbert_assist, :first_model_pull)
      end)

      Enum.each(provider_env_keys, &System.delete_env/1)
      System.put_env("OLLAMA_HOST", "https://example.invalid")
      FirstRun.reset_onboarding()
      FirstRun.mark_onboarding_complete()
      FirstRun.mark_profile_reviewed()
      Application.put_env(:allbert_assist, :first_model_state_override, :model_missing)

      # A puller that emits one progress frame, then blocks until released — so the
      # pull is provably still in-flight when we assert the frame has streamed in.
      Application.put_env(:allbert_assist, :first_model_pull, fn model, progress_context ->
        AllbertAssist.Signals.emit_first_model_pull_progress(
          Map.merge(progress_context, %{model: model, status: "pulling manifest", percent: 12})
        )

        send(test_pid, {:puller_blocked, self()})

        receive do
          :release_pull -> :ok
        after
          5_000 -> :ok
        end

        {:ok, %{status: "success"}, []}
      end)

      {:ok, view, _html} = live(conn, ~p"/workspace?#{[destination: "workspace:models"]}")
      assert has_element?(view, "#workspace-models-pull-model")

      # Dispatch is non-blocking: render_click returns immediately with the button in
      # its pulling state while the (blocked) pull runs in the async task. The pre-v0.64.3
      # synchronous dispatch could not render this — it blocked until the pull finished.
      html = view |> element("#workspace-models-pull-model") |> render_click()
      assert html =~ "Pulling starter model"

      assert_receive {:puller_blocked, puller_pid}, 2_000

      # The emitted frame streams to the panel live — before the pull completes.
      assert eventually(fn -> render(view) =~ "pulling manifest" end)

      # Release the pull and let the async task finalize without error.
      send(puller_pid, :release_pull)
      _html = render_async(view, @runtime_async_timeout)
    end
  end

  defp eventually(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _attempt, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end
end
