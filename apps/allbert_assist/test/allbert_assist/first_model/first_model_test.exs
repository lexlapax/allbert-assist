defmodule AllbertAssist.FirstModelTest do
  @moduledoc """
  v0.62 M4 — First-Model-Path: the Ollama three-way probe resolves the model
  states; the guided install and pull execute only behind an approved
  confirmation (the M4 Authority Contract), record their command/egress, and
  degrade to BYOK below the floor / on decline.
  """
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  alias AllbertAssist.Actions.FirstModel.{InstallOllama, PullModel}
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.FirstModel.{Hardware, Ollama}
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.SecurityFixtures.AssertBinding
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.TestSupport.ReadyEffectContext
  alias Jido.Signal.Bus

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_req_options = Application.get_env(:allbert_assist, :first_model_req_options)
    original_pull = Application.get_env(:allbert_assist, :first_model_pull)

    original_post_pull =
      Application.get_env(:allbert_assist, :first_model_post_pull_enablement)

    original_post_pull_doctor =
      Application.get_env(:allbert_assist, :first_model_post_pull_doctor)

    original_host = System.get_env("OLLAMA_HOST")

    Application.put_env(:allbert_assist, :first_model_post_pull_enablement, fn _model ->
      {:ok,
       %{
         state: :auto_enabled,
         model_state: :local_ready,
         selection: nil,
         provenance: nil
       }}
    end)

    on_exit(fn ->
      if original_req_options,
        do: Application.put_env(:allbert_assist, :first_model_req_options, original_req_options),
        else: Application.delete_env(:allbert_assist, :first_model_req_options)

      if original_pull,
        do: Application.put_env(:allbert_assist, :first_model_pull, original_pull),
        else: Application.delete_env(:allbert_assist, :first_model_pull)

      if original_post_pull,
        do:
          Application.put_env(
            :allbert_assist,
            :first_model_post_pull_enablement,
            original_post_pull
          ),
        else: Application.delete_env(:allbert_assist, :first_model_post_pull_enablement)

      if original_post_pull_doctor,
        do:
          Application.put_env(
            :allbert_assist,
            :first_model_post_pull_doctor,
            original_post_pull_doctor
          ),
        else: Application.delete_env(:allbert_assist, :first_model_post_pull_doctor)

      if original_host,
        do: System.put_env("OLLAMA_HOST", original_host),
        else: System.delete_env("OLLAMA_HOST")
    end)

    :ok
  end

  test "curated model and floor are settings-backed with schema defaults (v1.0 M7.5)" do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths = Application.get_env(:allbert_assist, AllbertAssist.Paths)
    original_settings = Application.get_env(:allbert_assist, AllbertAssist.Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-first-model-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(home)
    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, AllbertAssist.Paths, home: home)

    Application.put_env(:allbert_assist, AllbertAssist.Settings,
      root: Path.join(home, "settings")
    )

    on_exit(fn ->
      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      if original_paths,
        do: Application.put_env(:allbert_assist, AllbertAssist.Paths, original_paths),
        else: Application.delete_env(:allbert_assist, AllbertAssist.Paths)

      if original_settings,
        do: Application.put_env(:allbert_assist, AllbertAssist.Settings, original_settings),
        else: Application.delete_env(:allbert_assist, AllbertAssist.Settings)

      File.rm_rf!(home)
    end)

    assert Ollama.curated_model() == "llama3.2:3b"
    assert Ollama.curated_floor_gb() == 8

    assert {:ok, _setting} =
             AllbertAssist.Settings.put(
               "first_model.curated_model",
               "qwen2.5:3b",
               ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    assert {:ok, _setting} =
             AllbertAssist.Settings.put(
               "first_model.curated_floor_gb",
               16,
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert Ollama.curated_model() == "qwen2.5:3b"
    assert Ollama.curated_floor_gb() == 16
  end

  describe "Ollama.probe/1 (three-way, injected)" do
    test "model_ready when server up and the curated model is present" do
      assert Ollama.probe(
               binary?: fn -> true end,
               version: fn -> {:ok, "0.1"} end,
               tags: fn -> [Ollama.curated_model()] end
             ) == :model_ready
    end

    test "model_missing when server up but curated model absent" do
      assert Ollama.probe(
               binary?: fn -> true end,
               version: fn -> {:ok, "0.1"} end,
               tags: fn -> ["something-else"] end
             ) == :model_missing
    end

    test "unhealthy when the version endpoint is malformed" do
      assert Ollama.probe(
               binary?: fn -> true end,
               version: fn -> :unhealthy end,
               tags: fn -> [] end
             ) == :unhealthy
    end

    test "missing when neither binary nor server is present" do
      assert Ollama.probe(
               binary?: fn -> false end,
               version: fn -> :error end,
               tags: fn -> [] end
             ) == :missing
    end

    test "default localhost HTTP uses Req and parses version/tags" do
      Application.put_env(:allbert_assist, :first_model_req_options, plug: {Req.Test, __MODULE__})

      Req.Test.expect(__MODULE__, fn %{request_path: "/api/version"} = conn ->
        Req.Test.json(conn, %{"version" => "0.5.0"})
      end)

      assert Ollama.server_version(ReadyEffectContext.context()) == {:ok, "0.5.0"}

      Req.Test.expect(__MODULE__, fn %{request_path: "/api/tags"} = conn ->
        Req.Test.json(conn, %{
          "models" => [%{"name" => Ollama.curated_model()}]
        })
      end)

      assert Ollama.model_tags(ReadyEffectContext.context()) == [Ollama.curated_model()]
    end

    test "default HTTP refuses non-loopback OLLAMA_HOST" do
      System.put_env("OLLAMA_HOST", "https://example.com")

      assert Ollama.local_url("/api/version") == {:error, :non_loopback_host}
      assert Ollama.server_version() == :error
    end

    test "provider target matching is loopback-equivalent and endpoint-exact" do
      System.delete_env("OLLAMA_HOST")

      assert Ollama.provider_targets_host_runtime?("http://localhost:11434/v1")
      assert Ollama.provider_targets_host_runtime?("http://127.0.0.1:11434/v1/")
      refute Ollama.provider_targets_host_runtime?("http://127.0.0.1:11435/v1")
      refute Ollama.provider_targets_host_runtime?("http://127.0.0.1:11434/custom/v1")
      refute Ollama.provider_targets_host_runtime?("http://192.168.1.9:11434/v1")
      refute Ollama.provider_targets_host_runtime?("http://localhost:11434/v1?target=other")

      System.put_env("OLLAMA_HOST", "127.0.0.1:11500")
      assert Ollama.provider_targets_host_runtime?("http://localhost:11500/v1")
      refute Ollama.provider_targets_host_runtime?("http://localhost:11434/v1")
    end
  end

  test "Hardware.meets_floor? passes unknown RAM and honors a real floor" do
    # On this host RAM is detectable; a floor of 1 GB always passes, a floor of
    # 10_000 GB never does.
    assert Hardware.meets_floor?(1)
    refute Hardware.meets_floor?(1_000_000)
  end

  test "first_model_detect is read-only and reports a state" do
    assert {:ok, %{status: :completed, first_model: %{state: state}}} =
             Runner.run("first_model_detect", %{}, %{user_id: "local"})

    # v0.63 M7.1: the six real model-probe states — no synthetic `:blocked`.
    assert state in [
             :local_ready,
             :runtime_missing,
             :runtime_unhealthy,
             :model_missing,
             :below_hardware_floor,
             :byok_ready
           ]
  end

  describe "install_ollama (command_execute, confirmation-gated)" do
    test "the gate deny path executes nothing" do
      denied = %{user_id: "local", selected_action: "unregistered_boundary_probe"}

      assert {:ok, %{status: status, actions: [%{executed: false}]}} =
               InstallOllama.run(%{}, denied)

      assert status in [:denied, :error]
    end

    test "dry_run reports the allowlisted command without executing" do
      assert {:ok, %{status: :completed, actions: [%{executed: false, commands: commands}]}} =
               Runner.run("install_ollama", %{dry_run: true}, %{user_id: "local"})

      assert is_list(commands)
      assert commands != []
    end

    test "the install commands are allowlisted per OS (no shell pipeline)" do
      assert {:ok, commands} = InstallOllama.install_commands()

      for {cmd, args} <- commands do
        assert is_binary(cmd)
        assert is_list(args)
        refute cmd in ["sh", "bash", "zsh"] and "-c" in args
      end
    end

    test "the needs_confirmation gate persists a durable, listable record (M8.14)" do
      # v0.62 M8.14: the confirmation floor must create a Confirmations record so
      # `admin confirmations approve <id>` can complete the install. We assert the
      # record is created + listable + resumable (we do NOT approve — that would
      # shell out to the real installer). command_execute defaults to :denied; the
      # needs_confirmation floor only applies once the operator opts the permission
      # in, so we grant it first.
      assert {:ok, _} =
               AllbertAssist.Settings.put(
                 "permissions.command_execute",
                 "needs_confirmation",
                 ReadyEffectContext.attach(%{
                   audit?: false
                 })
               )

      assert {:ok, gated} =
               Runner.run("install_ollama", %{}, %{actor: "local", channel: :cli})

      assert gated.status == :needs_confirmation
      assert is_binary(gated.confirmation_id)

      assert {:ok, listed} =
               Runner.run("list_confirmations", %{}, %{actor: "local", channel: :cli})

      assert Enum.any?(listed.confirmations, &(&1["id"] == gated.confirmation_id))
    end
  end

  describe "pull_model (external_network, confirmation-gated)" do
    test "the gate deny path pulls nothing" do
      denied = %{user_id: "local", selected_action: "unregistered_boundary_probe"}

      assert {:ok, %{status: status, actions: [%{executed: false}]}} =
               PullModel.run(%{}, denied)

      assert status in [:denied, :error]
    end

    test "dry_run names the model + endpoint without egress" do
      assert {:ok, %{status: :completed, message: message, actions: [%{executed: false}]}} =
               Runner.run("pull_model", %{dry_run: true}, %{user_id: "local"})

      assert message =~ "/api/pull"
      assert message =~ Ollama.curated_model()
    end

    test "approved pull uses Req against the loopback Ollama API" do
      Application.put_env(:allbert_assist, :first_model_req_options, plug: {Req.Test, __MODULE__})

      Req.Test.expect(__MODULE__, fn %{method: "POST", request_path: "/api/pull"} = conn ->
        assert Req.Test.raw_body(conn) =~ Ollama.curated_model()
        assert Req.Test.raw_body(conn) =~ ~s("stream":true)
        Req.Test.json(conn, %{"status" => "success"})
      end)

      assert {:ok, %{status: :completed, actions: [%{executed: true, summary: summary}]}} =
               PullModel.run(%{}, ReadyEffectContext.attach(%{confirmation: %{approved?: true}}))

      assert summary.status == "success"
    end

    test "a completed DirectAnswer-model pull enables its exact configured task profile" do
      root =
        Path.join(
          System.tmp_dir!(),
          "allbert-post-pull-enable-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      saved_paths = Application.get_env(:allbert_assist, AllbertAssist.Paths)
      saved_settings = Application.get_env(:allbert_assist, AllbertAssist.Settings)
      saved_runner = Application.get_env(:allbert_assist, :first_model_post_pull_enablement)

      Application.put_env(:allbert_assist, AllbertAssist.Paths, home: root)

      Application.put_env(:allbert_assist, AllbertAssist.Settings,
        root: Path.join(root, "settings")
      )

      Application.delete_env(:allbert_assist, :first_model_post_pull_enablement)

      caller = self()

      Application.put_env(:allbert_assist, :first_model_post_pull_doctor, fn profile ->
        send(caller, {:post_pull_doctor, profile})
        {:ok, %{endpoint_ok: true, model_available: true}}
      end)

      Application.put_env(:allbert_assist, :first_model_pull, fn _model ->
        {:ok, %{status: "success"}, []}
      end)

      on_exit(fn ->
        if saved_paths,
          do: Application.put_env(:allbert_assist, AllbertAssist.Paths, saved_paths),
          else: Application.delete_env(:allbert_assist, AllbertAssist.Paths)

        if saved_settings,
          do: Application.put_env(:allbert_assist, AllbertAssist.Settings, saved_settings),
          else: Application.delete_env(:allbert_assist, AllbertAssist.Settings)

        if saved_runner,
          do:
            Application.put_env(
              :allbert_assist,
              :first_model_post_pull_enablement,
              saved_runner
            ),
          else: Application.delete_env(:allbert_assist, :first_model_post_pull_enablement)

        File.rm_rf!(root)
      end)

      assert {:ok, response} =
               PullModel.run(%{model: "qwen2.5:7b"}, %{
                 confirmation: %{approved?: true},
                 actor: "local"
               })

      assert response.status == :completed
      assert response.output_data.pulled_model == "qwen2.5:7b"
      assert response.output_data.enablement.state == :auto_enabled
      assert response.output_data.enablement.selection.profile == "direct_answer_local"
      assert_receive {:post_pull_doctor, "direct_answer_local"}
      assert AllbertAssist.Settings.get("intent.direct_answer_model_enabled") == {:ok, true}
      assert AllbertAssist.Settings.get("model_preferences.primary") == {:ok, "local"}

      assert AllbertAssist.Settings.get("model_preferences.tasks.direct_answer") ==
               {:ok, ["direct_answer_local"]}

      assert Disclosure.pending?(:web)
    end

    test "a host pull cannot enable a DirectAnswer profile whose configured endpoint is unavailable" do
      root =
        Path.join(
          System.tmp_dir!(),
          "allbert-post-pull-custom-endpoint-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      saved_paths = Application.get_env(:allbert_assist, AllbertAssist.Paths)
      saved_settings = Application.get_env(:allbert_assist, AllbertAssist.Settings)

      Application.put_env(:allbert_assist, AllbertAssist.Paths, home: root)

      Application.put_env(:allbert_assist, AllbertAssist.Settings,
        root: Path.join(root, "settings")
      )

      Application.delete_env(:allbert_assist, :first_model_post_pull_enablement)
      Application.put_env(:allbert_assist, :first_model_pull, fn _model -> {:ok, %{}, []} end)

      caller = self()

      Application.put_env(:allbert_assist, :first_model_post_pull_doctor, fn profile ->
        send(caller, {:post_pull_doctor, profile})
        {:ok, %{endpoint_ok: false, model_available: :unknown}}
      end)

      on_exit(fn ->
        if saved_paths,
          do: Application.put_env(:allbert_assist, AllbertAssist.Paths, saved_paths),
          else: Application.delete_env(:allbert_assist, AllbertAssist.Paths)

        if saved_settings,
          do: Application.put_env(:allbert_assist, AllbertAssist.Settings, saved_settings),
          else: Application.delete_env(:allbert_assist, AllbertAssist.Settings)

        File.rm_rf!(root)
      end)

      assert {:ok, response} =
               PullModel.run(%{model: "qwen2.5:7b"}, %{
                 confirmation: %{approved?: true},
                 actor: "local"
               })

      assert_receive {:post_pull_doctor, "direct_answer_local"}
      assert response.status == :completed
      assert response.output_data.enablement.state == :enabled_unavailable
      assert AllbertAssist.Settings.get("intent.direct_answer_model_enabled") == {:ok, false}
    end

    test "a completed pull preserves and discloses an explicit hosted DirectAnswer task" do
      root =
        Path.join(
          System.tmp_dir!(),
          "allbert-post-pull-hosted-primary-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      saved_paths = Application.get_env(:allbert_assist, AllbertAssist.Paths)
      saved_settings = Application.get_env(:allbert_assist, AllbertAssist.Settings)
      saved_runner = Application.get_env(:allbert_assist, :first_model_post_pull_enablement)
      saved_backend = System.get_env("ALLBERT_VAULT_BACKEND")
      saved_openai = System.get_env("OPENAI_API_KEY")

      Application.put_env(:allbert_assist, AllbertAssist.Paths, home: root)

      Application.put_env(:allbert_assist, AllbertAssist.Settings,
        root: Path.join(root, "settings")
      )

      Application.delete_env(:allbert_assist, :first_model_post_pull_enablement)
      Application.put_env(:allbert_assist, :first_model_pull, fn _model -> {:ok, %{}, []} end)
      System.put_env("ALLBERT_VAULT_BACKEND", "env")
      System.put_env("OPENAI_API_KEY", "operator-env-key")

      on_exit(fn ->
        if saved_paths,
          do: Application.put_env(:allbert_assist, AllbertAssist.Paths, saved_paths),
          else: Application.delete_env(:allbert_assist, AllbertAssist.Paths)

        if saved_settings,
          do: Application.put_env(:allbert_assist, AllbertAssist.Settings, saved_settings),
          else: Application.delete_env(:allbert_assist, AllbertAssist.Settings)

        if saved_runner,
          do:
            Application.put_env(
              :allbert_assist,
              :first_model_post_pull_enablement,
              saved_runner
            ),
          else: Application.delete_env(:allbert_assist, :first_model_post_pull_enablement)

        if saved_backend,
          do: System.put_env("ALLBERT_VAULT_BACKEND", saved_backend),
          else: System.delete_env("ALLBERT_VAULT_BACKEND")

        if saved_openai,
          do: System.put_env("OPENAI_API_KEY", saved_openai),
          else: System.delete_env("OPENAI_API_KEY")

        File.rm_rf!(root)
      end)

      assert {:ok, _settings} =
               Store.write_user_settings(%{
                 "model_preferences" => %{
                   "tasks" => %{"direct_answer" => ["fast"]}
                 }
               })

      assert {:ok, response} =
               PullModel.run(%{}, %{confirmation: %{approved?: true}, actor: "local"})

      assert response.status == :completed
      assert response.output_data.enablement.state == :auto_enabled
      assert response.output_data.enablement.selection.profile == "fast"
      assert response.output_data.enablement.selection.provider_class == :hosted
      assert AllbertAssist.Settings.get("model_preferences.primary") == {:ok, "local"}

      assert AllbertAssist.Settings.get("model_preferences.tasks.direct_answer") ==
               {:ok, ["fast"]}

      assert Disclosure.hosted_pending?(:web)
      assert Disclosure.text(:web) =~ "will leave this device"
    end

    test "approved pull streams bounded progress signals to the workspace topic" do
      model = Ollama.curated_model()
      Application.put_env(:allbert_assist, :first_model_req_options, plug: {Req.Test, __MODULE__})

      assert {:ok, _subscription_id} =
               Bus.subscribe(
                 AllbertAssist.SignalBus,
                 "allbert.workspace.first_model.pull.progress"
               )

      Req.Test.expect(__MODULE__, fn %{method: "POST", request_path: "/api/pull"} = conn ->
        assert Req.Test.raw_body(conn) =~ ~s("stream":true)
        refute Req.Test.raw_body(conn) =~ "api_key"

        body =
          [
            Jason.encode!(%{status: "pulling manifest"}),
            Jason.encode!(%{status: "downloading", total: 100, completed: 50}),
            Jason.encode!(%{status: "success"})
          ]
          |> Enum.join("\n")

        conn
        |> Plug.Conn.put_resp_content_type("application/x-ndjson")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:ok, %{status: :completed, progress: progress, actions: [%{summary: summary}]}} =
               PullModel.run(
                 %{model: model, user_id: "user-web", thread_id: "thread-web"},
                 ReadyEffectContext.attach(%{confirmation: %{approved?: true}})
               )

      assert summary.status == "success"
      assert Enum.any?(progress, &(&1.status == "downloading" and &1.percent == 50.0))

      assert_receive {:signal,
                      %{
                        type: "allbert.workspace.first_model.pull.progress",
                        data: %{user_id: "user-web", thread_id: "thread-web"}
                      }},
                     1_000

      assert_receive {:signal,
                      %{
                        type: "allbert.workspace.first_model.pull.progress",
                        data: %{status: "downloading", percent: 50.0}
                      }},
                     1_000

      AssertBinding.check!("first-model-consumer-oneclick-download-progress-no-key-001", [
        :pull_uses_streaming_api,
        :progress_signal_emitted,
        :no_api_key_required
      ])
    end

    test "the durable confirmation round-trips create → approve → pull (M8.14)" do
      # v0.62 M8.14: the needs_confirmation floor persists a Confirmations record
      # carrying the requested model in resume_params_ref; approving it (the real
      # operator path, not an injected `approved?` stub) resumes the pull with that
      # exact model against the injected loopback Req.
      model = Ollama.curated_model()
      Application.put_env(:allbert_assist, :first_model_req_options, plug: {Req.Test, __MODULE__})

      Req.Test.expect(__MODULE__, fn %{method: "POST", request_path: "/api/pull"} = conn ->
        assert Req.Test.raw_body(conn) =~ model
        Req.Test.json(conn, %{"status" => "success"})
      end)

      assert {:ok, gated} =
               Runner.run("pull_model", %{model: model}, %{
                 actor: "local",
                 channel: :cli,
                 request: %{user_id: "local", thread_id: "thread-cli"}
               })

      assert gated.status == :needs_confirmation
      assert is_binary(gated.confirmation_id)
      assert get_in(gated.confirmation, ["resume_params_ref", "user_id"]) == "local"
      assert get_in(gated.confirmation, ["resume_params_ref", "thread_id"]) == "thread-cli"

      assert {:ok, approved} =
               Runner.run("approve_confirmation", %{id: gated.confirmation_id}, %{
                 actor: "local",
                 channel: :cli
               })

      assert approved.status == :completed
    end
  end
end
