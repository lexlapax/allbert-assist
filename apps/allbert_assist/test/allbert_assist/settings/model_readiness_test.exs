defmodule AllbertAssist.Settings.ModelReadinessTest do
  use ExUnit.Case, async: false

  @moduletag :external_runtime_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelReadiness
  alias AllbertAssist.Settings.ModelRecommendations
  alias AllbertAssist.Settings.ModelRuntime

  @provider_env ~w(ALLBERT_VAULT_BACKEND OLLAMA_BASE_URL OPENAI_API_KEY)

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_provider_env = Map.new(@provider_env, &{&1, System.get_env(&1)})

    Enum.each(@provider_env, &System.delete_env/1)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-model-readiness-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Paths, home: root)

    on_exit(fn ->
      restore_env(Settings, original_settings)
      restore_env(Paths, original_paths)
      restore_system_env(original_provider_env)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "configured hosted roles are callable without probing the provider" do
    test_pid = self()

    assert {:ok, _secret} =
             Settings.Secrets.put_secret(
               "secret://providers/openai/api_key",
               "operator-test-key",
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.fanout_manager",
               ["fast"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:unexpected_hosted_probe, conn.request_path})
      Req.Test.json(conn, %{"data" => []})
    end)

    assert %{
             manager: %{
               callable?: true,
               status: :callable,
               reason: nil,
               resolution_status: :resolved,
               doctor: nil,
               profile: %{name: "fast", credential_status: :configured}
             }
           } =
             ModelReadiness.check(
               %{manager: {:role, :fanout_manager}},
               %{req_options: [plug: {Req.Test, __MODULE__}]}
             )

    refute_received {:unexpected_hosted_probe, _path}
  end

  test "a hosted role without a configured credential is unavailable without probing" do
    test_pid = self()

    assert {:ok, _setting} =
             Settings.put(
               "providers.openai.enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.fanout_synthesis",
               ["fast"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:unexpected_hosted_probe, conn.request_path})
      Req.Test.json(conn, %{"data" => []})
    end)

    assert %{
             synthesis: %{
               callable?: false,
               status: :unavailable,
               reason: :credential_unavailable,
               resolution_status: :resolved,
               doctor: nil,
               profile: %{name: "fast", credential_status: :missing}
             }
           } =
             ModelReadiness.check(
               %{synthesis: {:role, :fanout_synthesis}},
               %{req_options: [plug: {Req.Test, __MODULE__}]}
             )

    refute_received {:unexpected_hosted_probe, _path}
  end

  test "an explicitly disabled exact local profile is unavailable without probing" do
    test_pid = self()

    assert {:ok, _setting} =
             Settings.put(
               "providers.local_ollama.enabled",
               false,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:unexpected_disabled_local_probe, conn.request_path})
      Req.Test.json(conn, %{"models" => [%{"model" => "qwen2.5:7b"}]})
    end)

    assert %{
             direct_answer: %{
               callable?: false,
               status: :unavailable,
               reason: :provider_disabled,
               resolution_status: :resolved,
               profile: %{name: "direct_answer_local"},
               doctor: nil
             }
           } =
             ModelReadiness.check(
               %{direct_answer: {:profile, "direct_answer_local"}},
               %{req_options: [plug: {Req.Test, __MODULE__}]}
             )

    refute_received {:unexpected_disabled_local_probe, _path}
  end

  test "an explicitly disabled exact hosted profile stays unavailable despite a credential" do
    test_pid = self()

    assert {:ok, _secret} =
             Settings.Secrets.put_secret(
               "secret://providers/openai/api_key",
               "operator-test-key",
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put(
               "providers.openai.enabled",
               false,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:unexpected_disabled_hosted_probe, conn.request_path})
      Req.Test.json(conn, %{"data" => []})
    end)

    assert %{
             hosted: %{
               callable?: false,
               status: :unavailable,
               reason: :provider_disabled,
               resolution_status: :resolved,
               profile: %{name: "fast", credential_status: :configured},
               doctor: nil
             }
           } =
             ModelReadiness.check(
               %{hosted: {:profile, "fast"}},
               %{req_options: [plug: {Req.Test, __MODULE__}]}
             )

    refute_received {:unexpected_disabled_hosted_probe, _path}
  end

  test "one local probe serves every role that resolves to the same profile" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/tags"

      Req.Test.json(conn, %{
        "models" => [%{"model" => "qwen2.5:7b", "context_length" => 32_768}]
      })
    end)

    readiness =
      ModelReadiness.check(
        %{
          direct_answer: {:role, :direct_answer},
          manager: {:role, :fanout_manager},
          synthesis: {:role, :fanout_synthesis}
        },
        %{req_options: [plug: {Req.Test, __MODULE__}]}
      )

    assert Map.keys(readiness) |> Enum.sort() ==
             [:direct_answer, :manager, :synthesis]

    for {_id, result} <- readiness do
      assert result.callable?
      assert result.status == :callable
      assert result.reason == nil
      assert result.resolution_status == :resolved
      assert result.profile.name == "direct_answer_local"
      assert result.doctor.endpoint_ok == true
      assert result.doctor.model_available == true
    end
  end

  test "local readiness probes the effective Ollama endpoint override" do
    assert {:ok, _setting} =
             Settings.put(
               "providers.local_ollama.base_url",
               "http://127.0.0.1:1/v1",
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    System.put_env("OLLAMA_BASE_URL", "http://127.0.0.1:11435/v1")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "127.0.0.1"
      assert conn.port == 11_435
      assert conn.request_path == "/api/tags"

      Req.Test.json(conn, %{
        "models" => [%{"model" => "qwen2.5:7b", "context_length" => 32_768}]
      })
    end)

    assert %{
             manager: %{
               callable?: true,
               status: :callable,
               doctor: %{redacted_host: "127.0.0.1", model_available: true}
             }
           } =
             ModelReadiness.check(
               %{manager: {:role, :fanout_manager}},
               %{req_options: [plug: {Req.Test, __MODULE__}]}
             )
  end

  test "an unavailable Ollama override cannot borrow configured-endpoint readiness" do
    assert {:ok, _setting} =
             Settings.put(
               "providers.local_ollama.base_url",
               "http://127.0.0.1:11435/v1",
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    System.put_env("OLLAMA_BASE_URL", "http://127.0.0.1:1/v1")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "127.0.0.1"
      assert conn.port == 1
      Plug.Conn.send_resp(conn, 503, "unavailable")
    end)

    assert %{
             manager: %{
               callable?: false,
               status: :unavailable,
               reason: :endpoint_unavailable,
               doctor: %{redacted_host: "127.0.0.1", endpoint_ok: false}
             }
           } =
             ModelReadiness.check(
               %{manager: {:role, :fanout_manager}},
               %{req_options: [plug: {Req.Test, __MODULE__}]}
             )
  end

  test "a local profile rejects a non-loopback Ollama override without probing" do
    test_pid = self()
    System.put_env("OLLAMA_BASE_URL", "https://models.example.test/v1")

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:unexpected_remote_override_probe, conn.host})
      Req.Test.json(conn, %{"models" => [%{"model" => "qwen2.5:7b"}]})
    end)

    assert %{
             manager: %{
               callable?: false,
               status: :unavailable,
               reason: :endpoint_unavailable,
               doctor: nil
             }
           } =
             ModelReadiness.check(
               %{manager: {:role, :fanout_manager}},
               %{req_options: [plug: {Req.Test, __MODULE__}]}
             )

    refute_received {:unexpected_remote_override_probe, _host}
  end

  test "a hosted-class openai-compatible profile with a local override is probed locally" do
    assert {:ok, _setting} =
             Settings.put(
               "providers.local_ollama.endpoint_kind",
               "credentialed_remote",
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    System.put_env("OLLAMA_BASE_URL", "http://127.0.0.1:11435/v1")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "127.0.0.1"
      assert conn.port == 11_435
      assert conn.request_path == "/v1/models"

      Req.Test.json(conn, %{
        "data" => [%{"id" => "qwen2.5:7b", "context_window" => 32_768}]
      })
    end)

    assert %{
             direct_answer: %{
               callable?: true,
               status: :callable,
               reason: nil,
               doctor: %{
                 endpoint_kind: :credentialed_remote,
                 effective_endpoint_class: :local,
                 redacted_host: "127.0.0.1",
                 endpoint_ok: true,
                 model_available: true
               }
             }
           } =
             ModelReadiness.check(
               %{direct_answer: {:profile, "direct_answer_local"}},
               %{req_options: [plug: {Req.Test, __MODULE__}]}
             )
  end

  test "effective endpoint validation is central, secret-free, and class-safe" do
    local_profile = %{
      provider: "local_ollama",
      provider_type: "openai_compatible",
      provider_endpoint_kind: "local_endpoint",
      provider_base_url: "http://localhost:11434/v1"
    }

    for invalid <- [
          "http://operator:secret@localhost:11434/v1",
          "http://localhost:11434/v1?token=secret",
          "http://localhost:11434/v1#secret"
        ] do
      System.put_env("OLLAMA_BASE_URL", invalid)

      assert {:error, :invalid_effective_model_endpoint} =
               ModelRuntime.effective_transport(local_profile)

      assert_raise ArgumentError, "invalid effective model endpoint", fn ->
        ModelRuntime.request_opts(local_profile)
      end
    end

    System.put_env("OLLAMA_BASE_URL", "https://models.example.test/v1")

    assert {:error, :non_loopback_local_model_endpoint} =
             ModelRuntime.effective_transport(local_profile)

    System.put_env("OLLAMA_BASE_URL", "http://host.docker.internal:11434/v1")

    assert {:ok, %{endpoint_class: :local, redacted_host: "host.docker.internal"}} =
             ModelRuntime.effective_transport(local_profile)

    hosted_profile = %{
      local_profile
      | provider: "hosted_compatible",
        provider_endpoint_kind: "credentialed_remote"
    }

    System.put_env("OLLAMA_BASE_URL", "https://models.example.test/v1")

    assert {:ok,
            %{
              endpoint_class: :hosted,
              endpoint_sha256: endpoint_sha256,
              redacted_host: "models.example.test"
            }} = ModelRuntime.effective_transport(hosted_profile)

    assert endpoint_sha256 =~ ~r/^[0-9a-f]{64}$/
    refute inspect(ModelRuntime.effective_transport(hosted_profile)) =~ "token="
  end

  test "the recommendation report probes each distinct local profile once" do
    counter = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(counter, 1, 1)
      assert conn.request_path == "/api/tags"

      Req.Test.json(conn, %{
        "models" => [
          %{"model" => "nomic-embed-text"},
          %{"model" => "llama3.1:8b"},
          %{"model" => "gemma4:26b"},
          %{"model" => "qwen2.5:7b"}
        ]
      })
    end)

    report =
      ModelRecommendations.diagnose(%{req_options: [plug: {Req.Test, __MODULE__}]})

    rows = Map.new(report.rows, &{&1.id, &1})

    for id <- ~w[direct_answer fanout_manager fanout_synthesis] do
      assert rows[id].status == "ok"
      assert rows[id].doctor.endpoint_ok == true
      assert rows[id].doctor.model_available == true
    end

    assert :counters.get(counter, 1) == 4
  end

  test "the direct-answer recommendation follows the task chain's primary fallback" do
    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.direct_answer",
               [],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/api/tags"

      Req.Test.json(conn, %{
        "models" => [
          %{"model" => "nomic-embed-text"},
          %{"model" => "llama3.1:8b"},
          %{"model" => "gemma4:26b"},
          %{"model" => "llama3.2:3b"}
        ]
      })
    end)

    report =
      ModelRecommendations.diagnose(
        %{req_options: [plug: {Req.Test, __MODULE__}]},
        scope: :intent
      )

    row = Enum.find(report.rows, &(&1.id == "direct_answer"))

    assert %{
             role: "direct_answer",
             chain_kind: "closed_task",
             configured_profile: nil,
             configured_profiles: [],
             configured_model: nil,
             configured_provider: nil,
             endpoint_kind: nil,
             resolution_status: "resolved",
             resolved_profile: "local",
             resolved_model: "llama3.2:3b",
             resolved_provider: "local_ollama",
             role_readiness: "under-capable",
             unavailable_role: "direct_answer",
             auto_pull: false,
             status: "under-capable",
             doctor: %{endpoint_ok: true, model_available: true}
           } = row

    assert row.diagnostics == ["resolved local model is below the recommended size"]

    assert row.fallback ==
             "Empty-chain compatibility uses the global primary; a non-empty task chain has no implicit primary fallback."

    assert ModelRecommendations.render(report) =~
             "direct_answer status=under-capable chain=[] resolved=local(llama3.2:3b) unavailable-role=direct_answer auto-pull=false key=model_preferences.tasks.direct_answer"
  end

  test "a reachable local endpoint without the selected model is model-not-pulled" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/tags"
      Req.Test.json(conn, %{"models" => [%{"model" => "llama3.2:3b"}]})
    end)

    assert %{
             direct_answer: %{
               callable?: false,
               status: :model_not_pulled,
               reason: :model_not_pulled,
               resolution_status: :resolved,
               doctor: %{endpoint_ok: true, model_available: false}
             }
           } =
             ModelReadiness.check(
               %{direct_answer: {:role, :direct_answer}},
               %{req_options: [plug: {Req.Test, __MODULE__}]}
             )
  end

  test "a local endpoint failure is unavailable rather than model-not-pulled" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

    assert %{
             synthesis: %{
               callable?: false,
               status: :unavailable,
               reason: :endpoint_unavailable,
               resolution_status: :resolved,
               doctor: %{endpoint_ok: false, model_available: :unknown}
             }
           } =
             ModelReadiness.check(
               %{synthesis: {:role, :fanout_synthesis}},
               %{req_options: [plug: {Req.Test, __MODULE__}]}
             )
  end

  test "an unreadable local inventory is unknown unavailable, not model-not-pulled" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "not-json") end)

    assert %{
             synthesis: %{
               callable?: false,
               status: :unavailable,
               reason: :availability_unknown,
               resolution_status: :resolved,
               doctor: %{endpoint_ok: true, model_available: :unknown}
             }
           } =
             ModelReadiness.check(
               %{synthesis: {:role, :fanout_synthesis}},
               %{req_options: [plug: {Req.Test, __MODULE__}]}
             )
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_system_env(values) do
    Enum.each(values, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end
end
