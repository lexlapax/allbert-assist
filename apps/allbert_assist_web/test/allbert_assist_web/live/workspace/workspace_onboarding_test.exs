defmodule AllbertAssistWeb.WorkspaceOnboardingTest do
  use AllbertAssistWeb.ConnCase, async: false
  use AllbertAssistWeb.WorkspaceLiveCase

  import Phoenix.LiveViewTest

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Store
  alias AllbertTUI.Adapter
  alias AllbertTUI.IdentityBootstrap

  @runtime_async_timeout 60_000

  describe "v1.2 model disclosure" do
    setup do
      saved = FirstRun.read_marker()

      on_exit(fn ->
        FirstRun.reset_onboarding()
        if saved != %{}, do: FirstRun.merge_marker(saved)
      end)

      :ok
    end

    test "requires the exact mounted handle before hosted web transport is admitted", %{
      conn: conn
    } do
      :ok =
        Disclosure.mark_pending(%{
          profile: "fast",
          provider: "openai",
          provider_class: :hosted
        })

      {:ok, view, _html} = live(conn, ~p"/workspace")
      html = view |> element("#workspace-model-disclosure") |> render()
      assert html =~ "will leave this device for openai"
      [handle] = Regex.run(~r/data-delivery-handle="([^"]+)"/, html, capture: :all_but_first)

      render_hook(view, "ack_model_disclosure", %{"handle" => "forged"})
      assert has_element?(view, "#workspace-model-disclosure")
      assert Disclosure.hosted_pending?(:web)

      refreshed_html = view |> element("#workspace-model-disclosure") |> render()

      [refreshed_handle] =
        Regex.run(~r/data-delivery-handle="([^"]+)"/, refreshed_html, capture: :all_but_first)

      refute refreshed_handle == handle

      render_hook(view, "ack_model_disclosure", %{"handle" => refreshed_handle})
      refute has_element?(view, "#workspace-model-disclosure")
      refute Disclosure.pending?(:web)
    end

    test "a stale acknowledgement refreshes the exact changed route and its hook re-acks updates",
         %{conn: conn} do
      assert :ok =
               Disclosure.mark_pending(%{
                 profile: "fast",
                 provider: "openai",
                 provider_class: :hosted
               })

      {:ok, view, _html} = live(conn, ~p"/workspace")
      first_html = view |> element("#workspace-model-disclosure") |> render()
      assert first_html =~ "will leave this device for openai"

      [first_handle] =
        Regex.run(~r/data-delivery-handle="([^"]+)"/, first_html, capture: :all_but_first)

      assert :ok =
               Disclosure.mark_pending(%{
                 profile: "anthropic_fast",
                 provider: "anthropic",
                 provider_class: :hosted
               })

      render_hook(view, "ack_model_disclosure", %{"handle" => first_handle})

      second_html = view |> element("#workspace-model-disclosure") |> render()
      assert second_html =~ "will leave this device for anthropic"

      [second_handle] =
        Regex.run(~r/data-delivery-handle="([^"]+)"/, second_html, capture: :all_but_first)

      refute second_handle == first_handle
      assert Disclosure.hosted_pending?(:web)

      app_js = File.read!(Path.expand("../../../../assets/js/app.js", __DIR__))
      assert app_js =~ "const ModelDisclosureAck = {"
      assert app_js =~ "updated()"
      assert app_js =~ "handle !== this.lastDeliveryHandle"

      render_hook(view, "ack_model_disclosure", %{"handle" => second_handle})
      refute has_element?(view, "#workspace-model-disclosure")
      refute Disclosure.pending?(:web)
    end

    test "web first-run presentation preview never writes settings or disclosure state", %{
      conn: conn
    } do
      saved_backend = System.get_env("ALLBERT_VAULT_BACKEND")
      saved_openai = System.get_env("OPENAI_API_KEY")

      on_exit(fn ->
        restore_system_env("ALLBERT_VAULT_BACKEND", saved_backend)
        restore_system_env("OPENAI_API_KEY", saved_openai)
      end)

      System.put_env("ALLBERT_VAULT_BACKEND", "env")
      System.put_env("OPENAI_API_KEY", "web-preview-only-key")
      FirstRun.reset_onboarding()
      assert {:ok, %{}} = Store.read_user_settings()

      {:ok, view, _html} = live(conn, ~p"/workspace")

      assert {:ok, %{}} = Store.read_user_settings()
      refute Disclosure.pending?(:web)
      refute has_element?(view, "#workspace-model-disclosure")
    end

    test "a same-session hosted route switch renders disclosure and admits no provider call before acknowledgement",
         %{conn: conn} do
      saved_runtime = Application.get_env(:allbert_assist, Runtime)
      saved_backend = System.get_env("ALLBERT_VAULT_BACKEND")
      saved_openai = System.get_env("OPENAI_API_KEY")
      test_pid = self()

      on_exit(fn ->
        restore_app_env(Runtime, saved_runtime)
        restore_system_env("ALLBERT_VAULT_BACKEND", saved_backend)
        restore_system_env("OPENAI_API_KEY", saved_openai)
      end)

      System.put_env("ALLBERT_VAULT_BACKEND", "env")
      System.put_env("OPENAI_API_KEY", "workspace-disclosure-test-key")

      Application.put_env(:allbert_assist, Runtime,
        agent_runner: fn _signal, request ->
          send(test_pid, {:runtime_disclosure_request, request.text})

          {:ok, profile} = Settings.resolve_model_profile("fast")

          case Disclosure.authorize_transport(profile, %{request: request}) do
            :ok ->
              send(test_pid, {:provider_called, profile.name})
              {:ok, %{message: "Hosted answer", status: :completed, actions: []}}

            {:error, reason} ->
              {:ok,
               %{
                 message: "Hosted disclosure required: #{inspect(reason)}",
                 status: :completed,
                 actions: []
               }}
          end
        end
      )

      assert {:ok, _setting} =
               Settings.put(
                 "model_preferences.tasks.direct_answer",
                 ["direct_answer_local"],
                 AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                   audit?: false
                 })
               )

      assert {:ok, _setting} =
               Settings.put(
                 "intent.direct_answer_model_enabled",
                 true,
                 AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
               )

      assert :ok = Disclosure.acknowledge(:web)

      {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:settings")
      refute has_element?(view, "#workspace-model-disclosure")

      view |> element("#use-model-fast") |> render_click()

      assert eventually(fn -> has_element?(view, "#workspace-model-disclosure") end)
      disclosure_html = view |> element("#workspace-model-disclosure") |> render()
      assert disclosure_html =~ "will leave this device for openai"

      view
      |> form("#agent-form", %{"prompt" => "Answer through the selected hosted model"})
      |> render_submit()

      assert has_element?(view, "#workspace-model-disclosure")
      refute_receive {:runtime_disclosure_request, _prompt}, 100
      refute_receive {:provider_called, _profile}, 100

      [handle] =
        Regex.run(~r/data-delivery-handle="([^"]+)"/, render(view), capture: :all_but_first)

      render_hook(view, "ack_model_disclosure", %{"handle" => handle})
      refute has_element?(view, "#workspace-model-disclosure")

      view |> element("#workspace-dest-output") |> render_click()

      view
      |> form("#agent-form", %{"prompt" => "Answer through the selected hosted model"})
      |> render_submit()

      assert_receive {:runtime_disclosure_request, "Answer through the selected hosted model"},
                     2_000

      assert_receive {:provider_called, "fast"}, 2_000
      assert render_async(view, @runtime_async_timeout) =~ "Hosted answer"
    end

    test "a completed TUI turn remains available to the production web workspace", %{conn: conn} do
      parent = self()

      Application.put_env(:allbert_assist, Runtime,
        agent_runner: fn _signal, request ->
          send(parent, {:tui_runtime_request, request})

          {:ok,
           %{
             model_payload: "TUI continuity response",
             surface_payload: "TUI continuity response",
             status: :completed
           }}
        end
      )

      assert {:ok, %{disposition: :bootstrapped}} =
               IdentityBootstrap.prepare_local_launch()

      assert {:ok, adapter} =
               Adapter.start_link(
                 name: nil,
                 auto_input?: false,
                 enabled?: true,
                 live_screen?: false,
                 output_fun: fn _line -> :ok end
               )

      assert {:ok, {:processed, event, _rendered}} =
               Adapter.submit(adapter, "tui to web continuity",
                 external_event_id: "evt-v12-tui-web-continuity"
               )

      assert_receive {:tui_runtime_request, %{user_id: "local"}}
      assert %Event{user_id: "local", thread_id: thread_id} = Repo.get!(Event, event.id)
      GenServer.stop(adapter)

      {:ok, _view, html} = live(conn, ~p"/workspace?thread_id=#{thread_id}")
      assert html =~ "tui to web continuity"
      assert html =~ "TUI continuity response"
      assert Settings.get("channels.tui.enabled") == {:ok, true}
    end
  end

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

    test "v1.2 M4: models panel and onboarding render the shared catalog", %{conn: conn} do
      {:ok, models_view, _html} = live(conn, ~p"/workspace?destination=workspace:models")
      assert has_element?(models_view, "#workspace-model-catalog")
      assert has_element?(models_view, "[id^='workspace-catalog-row-ollama-llama3-2-3b']")

      {:ok, onboarding_view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")
      onboarding_view |> element("#workspace-wizard-enter-model_path") |> render_click()
      assert has_element?(onboarding_view, "#workspace-onboarding-model-catalog")
    end

    test "v1.3: surfaces distinguish a ready substrate from an unavailable DirectAnswer model",
         %{conn: conn} do
      isolate_empty_ollama_inventory!()
      saved_override = Application.get_env(:allbert_assist, :first_model_state_override)

      on_exit(fn -> restore_app_env(:first_model_state_override, saved_override) end)

      Application.put_env(:allbert_assist, :first_model_state_override, :local_ready)

      {:ok, onboarding_view, _html} =
        live(conn, ~p"/workspace?destination=workspace:onboard")

      onboarding_view |> element("#workspace-wizard-enter-model_path") |> render_click()

      readiness_html =
        onboarding_view
        |> element("#workspace-onboarding-readiness")
        |> render()

      direct_answer_html =
        onboarding_view
        |> element("#workspace-direct-answer-readiness")
        |> render()

      assert readiness_html =~ "Ready"
      assert direct_answer_html =~ "DirectAnswer: Needs model selection"

      {:ok, models_view, _html} = live(conn, ~p"/workspace?destination=workspace:models")

      repair_headline =
        models_view
        |> element("#workspace-model-repair-headline")
        |> render()

      repair_next =
        models_view
        |> element("#workspace-model-repair-next")
        |> render()

      assert repair_headline =~ "selected DirectAnswer model is unavailable"
      assert repair_next =~ "confirmation-gated repair"
    end

    test "v1.3: wizard navigation keeps one readiness snapshot until an explicit model refresh",
         %{conn: conn} do
      isolate_empty_ollama_inventory!()
      saved_override = Application.get_env(:allbert_assist, :first_model_state_override)

      on_exit(fn -> restore_app_env(:first_model_state_override, saved_override) end)

      Application.put_env(:allbert_assist, :first_model_state_override, :runtime_missing)

      {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")

      Application.put_env(:allbert_assist, :first_model_state_override, :local_ready)

      view |> element("#workspace-wizard-enter-model_path") |> render_click()

      cached_html = view |> element("#workspace-direct-answer-readiness") |> render()
      cached_substrate_html = view |> element("#workspace-onboarding-readiness") |> render()
      assert cached_html =~ "DirectAnswer: Needs runtime"
      assert cached_substrate_html =~ "Needs runtime"

      view |> element("#workspace-provider-doctor") |> render_click()

      refreshed_html = view |> element("#workspace-direct-answer-readiness") |> render()
      refreshed_substrate_html = view |> element("#workspace-onboarding-readiness") |> render()
      assert refreshed_html =~ "DirectAnswer: Needs model selection"
      assert refreshed_substrate_html =~ "Ready"
    end

    test "v1.3: model surfaces pull the exact selected local catalog model", %{conn: conn} do
      saved_http = Application.get_env(:allbert_assist, :first_model_http)
      saved_puller = Application.get_env(:allbert_assist, :first_model_pull)
      saved_post_pull = Application.get_env(:allbert_assist, :first_model_post_pull_enablement)
      test_pid = self()

      on_exit(fn ->
        restore_app_env(:first_model_http, saved_http)
        restore_app_env(:first_model_pull, saved_puller)
        restore_app_env(:first_model_post_pull_enablement, saved_post_pull)
      end)

      Application.put_env(:allbert_assist, :first_model_http, fn url ->
        if String.ends_with?(url, "/api/tags"),
          do: {:ok, %{"models" => []}},
          else: {:ok, %{"version" => "test"}}
      end)

      Application.put_env(:allbert_assist, :first_model_pull, fn model ->
        send(test_pid, {:catalog_model_pulled, model})
        {:ok, %{status: "success"}, []}
      end)

      Application.put_env(:allbert_assist, :first_model_post_pull_enablement, fn _model ->
        {:ok, %{state: :enabled_unavailable}}
      end)

      {:ok, models_view, _html} = live(conn, ~p"/workspace?destination=workspace:models")

      assert has_element?(
               models_view,
               "#workspace-catalog-pull-ollama-qwen2-5-7b[phx-value-entry-id='ollama:qwen2.5:7b']"
             )

      refute has_element?(
               models_view,
               "#workspace-catalog-pull-profile-direct_answer_local"
             )

      assert has_element?(
               models_view,
               "#workspace-catalog-use-profile-direct_answer_local"
             )

      refute has_element?(models_view, "#workspace-catalog-pull-openai-configured")

      models_view
      |> element("#workspace-catalog-pull-ollama-qwen2-5-7b")
      |> render_click()

      assert_receive {:catalog_model_pulled, "qwen2.5:7b"}, 2_000
      _html = render_async(models_view, @runtime_async_timeout)

      {:ok, onboarding_view, _html} =
        live(conn, ~p"/workspace?destination=workspace:onboard")

      onboarding_view |> element("#workspace-wizard-enter-model_path") |> render_click()

      assert has_element?(
               onboarding_view,
               "#workspace-onboarding-catalog-pull-ollama-qwen2-5-7b[phx-value-entry-id='ollama:qwen2.5:7b']"
             )

      onboarding_view
      |> element("#workspace-onboarding-catalog-pull-ollama-qwen2-5-7b")
      |> render_click()

      assert_receive {:catalog_model_pulled, "qwen2.5:7b"}, 2_000
      _html = render_async(onboarding_view, @runtime_async_timeout)
    end

    test "v1.3: model catalog selection changes DirectAnswer without changing the global primary",
         %{conn: conn} do
      assert {:ok, global_primary} = Settings.get("model_preferences.primary")

      {:ok, models_view, _html} = live(conn, ~p"/workspace?destination=workspace:models")

      assert has_element?(
               models_view,
               "#workspace-catalog-use-profile-fast[phx-value-entry-id='profile:fast']"
             )

      refute has_element?(models_view, "#workspace-catalog-use-ollama-qwen2-5-7b")

      models_view
      |> element("#workspace-catalog-use-profile-fast")
      |> render_click()

      assert {:ok, ["fast" | _tail]} =
               Settings.get("model_preferences.tasks.direct_answer")

      assert Settings.get("model_preferences.primary") == {:ok, global_primary}

      {:ok, onboarding_view, _html} =
        live(conn, ~p"/workspace?destination=workspace:onboard")

      onboarding_view |> element("#workspace-wizard-enter-model_path") |> render_click()

      assert has_element?(
               onboarding_view,
               "#workspace-onboarding-catalog-use-profile-direct_answer_local[phx-value-entry-id='profile:direct_answer_local']"
             )

      refute has_element?(onboarding_view, "[id^='workspace-provider-use-']")

      onboarding_view
      |> element("#workspace-onboarding-catalog-use-profile-direct_answer_local")
      |> render_click()

      assert {:ok, ["direct_answer_local" | _tail]} =
               Settings.get("model_preferences.tasks.direct_answer")

      assert Settings.get("model_preferences.primary") == {:ok, global_primary}
    end

    test "v1.3: a custom DirectAnswer endpoint never offers an unrelated host pull",
         %{conn: conn} do
      isolate_empty_ollama_inventory!()

      assert {:ok, _setting} =
               Settings.put(
                 "providers.local_ollama.base_url",
                 "http://127.0.0.1:2/v1",
                 AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                   audit?: false
                 })
               )

      {:ok, models_view, _html} = live(conn, ~p"/workspace?destination=workspace:models")
      assert has_element?(models_view, "#workspace-catalog-pull-ollama-qwen2-5-7b")

      {:ok, onboarding_view, _html} =
        live(conn, ~p"/workspace?destination=workspace:onboard")

      onboarding_view |> element("#workspace-wizard-enter-model_path") |> render_click()

      refute has_element?(
               onboarding_view,
               "#workspace-onboarding-catalog-pull-ollama-qwen2-5-7b"
             )
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

    test "v1.2 M3: every step opens after completion without clearing completion", %{conn: conn} do
      FirstRun.reset_onboarding()

      FirstRun.merge_marker(%{
        "wizard_started" => true,
        "track" => "quickstart",
        "wizard_done" =>
          ~w(welcome track_select model_path profile_select profile_review health_check first_chat),
        "wizard_step" => "first_chat",
        "onboarding_complete" => true
      })

      {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")

      for step <- AllbertAssist.Onboarding.wizard_steps() do
        assert has_element?(view, "#workspace-wizard-enter-#{step}")
      end

      view |> element("#workspace-wizard-enter-optional_connect") |> render_click()
      assert has_element?(view, "#workspace-wizard-step-optional_connect[data-current='true']")
      assert has_element?(view, "#workspace-wizard-step-controls")
      assert FirstRun.read_marker()["onboarding_complete"] == true
    end

    test "v1.2 M3: sticky disable shows the re-enable affordance only once", %{conn: conn} do
      FirstRun.reset_onboarding()

      assert {:ok, _setting} =
               Settings.put(
                 "intent.direct_answer_model_enabled",
                 false,
                 AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
               )

      FirstRun.merge_marker(%{
        "wizard_started" => true,
        "wizard_direct_entry" => true,
        "wizard_step" => "model_path",
        "model_answers_declined" => true
      })

      {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")
      assert has_element?(view, "#workspace-model-reenable-affordance")
      assert FirstRun.read_marker()["model_reenable_offered"] == true

      {:ok, second_view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")
      refute has_element?(second_view, "#workspace-model-reenable-affordance")

      view |> element("#workspace-model-reenable") |> render_click()
      assert Settings.get("intent.direct_answer_model_enabled") == {:ok, true}
    end

    test "v1.2: fresh empty chat shows one primary repair CTA without a wizard wall",
         %{conn: conn} do
      isolate_empty_provider_vault!()
      isolate_empty_ollama_inventory!()
      saved_override = Application.get_env(:allbert_assist, :first_model_state_override)

      on_exit(fn -> restore_app_env(:first_model_state_override, saved_override) end)

      Application.put_env(:allbert_assist, :first_model_state_override, :runtime_missing)
      FirstRun.reset_onboarding()
      {:ok, view, _html} = live(conn, ~p"/workspace")

      assert has_element?(
               view,
               "#workspace-model-repair-cta[data-primary-cta='install_runtime']"
             )

      assert has_element?(
               view,
               "#workspace-model-repair-primary[data-model-repair-action='install_runtime']"
             )

      repair_html = view |> element("#workspace-model-repair-cta") |> render()
      assert length(Regex.scan(~r/workspace-button-primary/, repair_html)) == 1
      assert has_element?(view, "#workspace-onboarding-optional")
      assert has_element?(view, "#agent-form")
      refute has_element?(view, "#workspace-onboarding-wizard")
      refute has_element?(view, "#workspace-suggested-action-guided-setup")

      view
      |> form("#agent-form", %{"prompt" => "What is the capital of France?"})
      |> render_submit()

      _html = render_async(view, @runtime_async_timeout)

      assert has_element?(view, "#agent-response")
      assert has_element?(view, "#workspace-model-repair-cta")
    end

    test "v1.3: onboarding keeps starter pull separate from DirectAnswer model repair",
         %{conn: conn} do
      isolate_empty_provider_vault!()
      isolate_empty_ollama_inventory!()
      install_fake_host_model_pull!()
      saved_override = Application.get_env(:allbert_assist, :first_model_state_override)
      saved_post_pull = Application.get_env(:allbert_assist, :first_model_post_pull_enablement)

      on_exit(fn ->
        restore_app_env(:first_model_state_override, saved_override)
        restore_app_env(:first_model_post_pull_enablement, saved_post_pull)
      end)

      FirstRun.reset_onboarding()

      FirstRun.merge_marker(%{
        "wizard_started" => true,
        "wizard_direct_entry" => true,
        "wizard_step" => "model_path"
      })

      Application.put_env(:allbert_assist, :first_model_state_override, :model_missing)
      Application.delete_env(:allbert_assist, :first_model_post_pull_enablement)

      {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")
      live_view_pid = view.pid
      assert has_element?(view, "#workspace-model-pull")

      view |> element("#workspace-model-pull") |> render_click()
      _html = render_async(view, @runtime_async_timeout)

      refute Settings.get("intent.direct_answer_model_enabled") == {:ok, true}
      refute has_element?(view, "#workspace-model-disclosure")

      assert has_element?(view, "#workspace-onboarding-catalog-pull-ollama-qwen2-5-7b")

      view
      |> element("#workspace-onboarding-catalog-pull-ollama-qwen2-5-7b")
      |> render_click()

      _html = render_async(view, @runtime_async_timeout)

      assert eventually(fn ->
               Settings.get("intent.direct_answer_model_enabled") == {:ok, true} and
                 has_element?(view, "#workspace-model-disclosure")
             end)

      assert render(view) =~ "Pulled"
      assert view.pid == live_view_pid
      assert Process.alive?(live_view_pid)
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
      assert has_element?(view, "#workspace-onboarding-first-chat-ready")

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
      isolate_empty_ollama_inventory!()
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
      isolate_empty_ollama_inventory!()

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
      isolate_empty_ollama_inventory!()

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

    test "v1.3: qualified catalog pull enables a model-backed answer in the same browser session",
         %{conn: conn} do
      isolate_empty_provider_vault!()
      isolate_empty_ollama_inventory!()
      install_fake_host_model_pull!()
      saved_override = Application.get_env(:allbert_assist, :first_model_state_override)
      saved_post_pull = Application.get_env(:allbert_assist, :first_model_post_pull_enablement)
      saved_runtime = Application.get_env(:allbert_assist, Runtime)

      on_exit(fn ->
        restore_app_env(:first_model_state_override, saved_override)
        restore_app_env(:first_model_post_pull_enablement, saved_post_pull)
        restore_app_env(Runtime, saved_runtime)
      end)

      FirstRun.reset_onboarding()
      Application.put_env(:allbert_assist, :first_model_state_override, :runtime_missing)
      Application.delete_env(:allbert_assist, :first_model_post_pull_enablement)

      Application.put_env(:allbert_assist, Runtime,
        agent_runner: fn _signal, _request ->
          answer =
            if Settings.get("intent.direct_answer_model_enabled") == {:ok, true} do
              "Paris — model-backed answer"
            else
              "Model answers are unavailable; deterministic fallback remains available."
            end

          {:ok,
           %{
             message: answer,
             model_payload: answer,
             surface_payload: answer,
             status: :completed,
             actions: []
           }}
        end
      )

      {:ok, view, _html} = live(conn, ~p"/workspace")
      live_view_pid = view.pid

      assert has_element?(
               view,
               "#workspace-model-repair-cta[data-primary-cta='install_runtime']"
             )

      view
      |> form("#agent-form", %{"prompt" => "What is the capital of France?"})
      |> render_submit()

      first_html = render_async(view, @runtime_async_timeout)
      assert first_html =~ "deterministic fallback remains available"
      assert has_element?(view, "#workspace-model-repair-primary")

      # The runtime has now been started externally. Following the one repair
      # destination re-probes the open Models panel and exposes the explicit pull.
      Application.put_env(:allbert_assist, :first_model_state_override, :model_missing)
      view |> element("#workspace-model-repair-primary") |> render_click()
      assert has_element?(view, "#workspace-models-pull-model")

      view |> element("#workspace-models-pull-model") |> render_click()
      _html = render_async(view, @runtime_async_timeout)

      refute Settings.get("intent.direct_answer_model_enabled") == {:ok, true}

      assert has_element?(view, "#workspace-catalog-pull-ollama-qwen2-5-7b")

      view
      |> element("#workspace-catalog-pull-ollama-qwen2-5-7b")
      |> render_click()

      _html = render_async(view, @runtime_async_timeout)

      assert eventually(fn ->
               Settings.get("intent.direct_answer_model_enabled") == {:ok, true}
             end)

      assert eventually(fn ->
               not has_element?(view, "#workspace-model-repair-cta") and
                 has_element?(view, "#workspace-model-disclosure")
             end)

      view
      |> form("#agent-form", %{"prompt" => "What is the capital of France?"})
      |> render_submit()

      repaired_html = render_async(view, @runtime_async_timeout)
      assert repaired_html =~ "Paris — model-backed answer"
      assert view.pid == live_view_pid
      assert Process.alive?(live_view_pid)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp isolate_empty_provider_vault! do
    provider_env_keys =
      ~w(ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY GEMINI_API_KEY)

    saved_provider_env = Map.new(provider_env_keys, &{&1, System.get_env(&1)})
    saved_backend = System.get_env("ALLBERT_VAULT_BACKEND")

    Enum.each(provider_env_keys, &System.delete_env/1)
    System.put_env("ALLBERT_VAULT_BACKEND", "env")

    on_exit(fn ->
      Enum.each(saved_provider_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      if saved_backend,
        do: System.put_env("ALLBERT_VAULT_BACKEND", saved_backend),
        else: System.delete_env("ALLBERT_VAULT_BACKEND")
    end)
  end

  defp isolate_empty_ollama_inventory! do
    saved_http = Application.get_env(:allbert_assist, :first_model_http)
    saved_ollama_host = System.get_env("OLLAMA_HOST")

    System.put_env("OLLAMA_HOST", "http://127.0.0.1:1")

    assert {:ok, _setting} =
             Settings.put(
               "providers.local_ollama.base_url",
               "http://127.0.0.1:1/v1",
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    Application.put_env(:allbert_assist, :first_model_http, fn url ->
      if String.ends_with?(url, "/api/tags"),
        do: {:ok, %{"models" => []}},
        else: {:ok, %{"version" => "test"}}
    end)

    on_exit(fn ->
      restore_app_env(:first_model_http, saved_http)
      restore_system_env("OLLAMA_HOST", saved_ollama_host)
    end)
  end

  defp install_fake_host_model_pull! do
    saved_puller = Application.get_env(:allbert_assist, :first_model_pull)
    saved_doctor = Application.get_env(:allbert_assist, :first_model_post_pull_doctor)
    {:ok, inventory} = Agent.start_link(fn -> MapSet.new() end)

    Application.put_env(:allbert_assist, :first_model_pull, fn model ->
      Agent.update(inventory, &MapSet.put(&1, model))
      {:ok, %{status: "success"}, []}
    end)

    Application.put_env(:allbert_assist, :first_model_post_pull_doctor, fn profile ->
      model_available? =
        profile == "direct_answer_local" and
          Agent.get(inventory, &MapSet.member?(&1, "qwen2.5:7b"))

      {:ok, %{endpoint_ok: true, model_available: model_available?}}
    end)

    on_exit(fn ->
      restore_app_env(:first_model_pull, saved_puller)
      restore_app_env(:first_model_post_pull_doctor, saved_doctor)
    end)
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
