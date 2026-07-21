defmodule AllbertAssist.Security.OnboardingProviderEvalTest do
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.DoctorDiagnostics

  @secret "sk-test-secret-v039"
  @secret_body "raw-provider-body-sk-test-secret-v039"

  @v039_eval_ids [
    "onboarding-secret-redaction-001",
    "onboarding-doctor-no-leak-001",
    "onboarding-safe-keys-only-001",
    "provider-doctor-credentialed-branch-001",
    "provider-doctor-local-endpoint-branch-001",
    "provider-doctor-endpoint-kind-derivation-001",
    "provider-doctor-redacted-host-only-001",
    "default-model-profile-real-model-001",
    "local-model-missing-remediation-001",
    "local-model-present-doctor-pass-001"
  ]

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_memory_config = Application.get_env(:allbert_assist, Memory)

    home = temp_path("home")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Application.put_env(:allbert_assist, Memory, root: Path.join(home, "memory"))

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(Memory, original_memory_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "v0.39 onboarding/provider eval rows are registered in the inventory" do
    assert @v039_eval_ids ==
             :v039
             |> EvalInventory.rows_for_milestone()
             |> Enum.map(& &1.id)
  end

  test "onboarding evals keep secrets redacted and writes behind safe registered actions" do
    put_secret!("secret://providers/openai/api_key", @secret)

    redaction =
      run_eval(
        fixture("onboarding-secret-redaction-001", %{
          run: fn fixture ->
            {:ok, response} = Runner.run("list_provider_profiles", %{}, context())

            %{
              decision: :allowed,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                action: "list_provider_profiles",
                provider_names: Enum.map(response.providers, & &1.name)
              }
            }
          end
        })
      )

    assert_allowed(redaction)
    assert_no_secret_in(redaction, [@secret])

    safe_keys =
      run_eval(
        fixture("onboarding-safe-keys-only-001", %{
          run: fn fixture ->
            {:ok, response} =
              Runner.run(
                "set_active_model_profile",
                %{profile: "local", enable_assist: true},
                context()
              )

            written_keys = Enum.map(response.settings, & &1.key)

            %{
              decision:
                if(Enum.all?(written_keys, &Settings.safe_write_key?/1),
                  do: :allowed,
                  else: :denied
                ),
              result: response,
              trace: %{
                fixture_id: fixture.id,
                written_keys: written_keys,
                user_settings: user_setting_keys()
              }
            }
          end
        })
      )

    assert_allowed(safe_keys)

    assert Enum.sort(safe_keys.trace.written_keys) ==
             Enum.sort([
               "intent.model_assist_enabled",
               "intent.model_profile",
               "providers.local_ollama.enabled"
             ])
  end

  test "provider doctor evals enforce two branches and redacted summaries" do
    doctor_no_leak =
      run_eval(
        fixture("onboarding-doctor-no-leak-001", %{
          run: fn fixture ->
            put_secret!("secret://providers/openai/api_key", @secret)

            Req.Test.expect(__MODULE__, fn conn ->
              assert conn.request_path == "/v1/models"
              assert {"authorization", "Bearer #{@secret}"} in conn.req_headers

              Plug.Conn.send_resp(conn, 401, @secret_body)
            end)

            {:ok, response} =
              Runner.run(
                "doctor_model_profile",
                %{profile: "fast"},
                context(%{req_options: [plug: {Req.Test, __MODULE__}]})
              )

            %{
              decision: :allowed,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                doctor: response.doctor,
                diagnostic_codes: diagnostic_codes(response)
              }
            }
          end
        })
      )

    assert_allowed(doctor_no_leak)
    assert_no_secret_in(doctor_no_leak, [@secret, @secret_body])
    assert doctor_no_leak.result.doctor.credential_ok == false
    assert Enum.all?(doctor_no_leak.result.doctor.diagnostics, &DoctorDiagnostics.known?(&1.code))

    assert Enum.all?(
             doctor_no_leak.result.doctor.diagnostics,
             &(&1.message == DoctorDiagnostics.new(&1.code).message)
           )

    credentialed =
      run_eval(
        fixture("provider-doctor-credentialed-branch-001", %{
          run: fn fixture ->
            put_secret!("secret://providers/anthropic/api_key", @secret)

            Req.Test.expect(__MODULE__, fn conn ->
              assert conn.request_path == "/v1/models"
              assert {"x-api-key", @secret} in conn.req_headers
              assert {"anthropic-version", "2023-06-01"} in conn.req_headers

              Plug.Conn.send_resp(
                conn,
                200,
                Jason.encode!(%{
                  "data" => [
                    %{"id" => "claude-haiku-4-5-20251001", "context_window" => 200_000}
                  ]
                })
              )
            end)

            {:ok, response} =
              Runner.run(
                "doctor_model_profile",
                %{profile: "anthropic_fast"},
                context(%{req_options: [plug: {Req.Test, __MODULE__}]})
              )

            %{
              decision: :allowed,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                doctor: response.doctor
              }
            }
          end
        })
      )

    assert_allowed(credentialed)
    assert credentialed.result.doctor.endpoint_kind == :credentialed_remote
    assert credentialed.result.doctor.credential_ok
    assert credentialed.result.doctor.endpoint_ok
    assert credentialed.result.doctor.model_available
    assert credentialed.result.doctor.redacted_host == "api.anthropic.com"
    assert_no_secret_in(credentialed, [@secret])

    local_branch =
      run_eval(
        fixture("provider-doctor-local-endpoint-branch-001", %{
          run: fn fixture ->
            expect_local_tags(%{"models" => []})

            {:ok, response} =
              Runner.run(
                "doctor_model_profile",
                %{profile: "local"},
                context(%{req_options: [plug: {Req.Test, __MODULE__}]})
              )

            %{
              decision: :allowed,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                doctor: response.doctor
              }
            }
          end
        })
      )

    assert_allowed(local_branch)
    assert local_branch.result.doctor.endpoint_kind == :local_endpoint
    assert local_branch.result.doctor.credential_ok == nil
    assert local_branch.result.doctor.endpoint_ok

    endpoint_kind =
      run_eval(
        fixture("provider-doctor-endpoint-kind-derivation-001", %{
          run: fn fixture ->
            {:ok, _setting} =
              Settings.put("providers.local_ollama.endpoint_kind", "credentialed_remote", %{
                audit?: false
              })

            {:ok, response} = Runner.run("doctor_model_profile", %{profile: "local"}, context())

            %{
              decision:
                if(response.doctor.endpoint_kind == :credentialed_remote,
                  do: :allowed,
                  else: :denied
                ),
              result: response,
              trace: %{
                fixture_id: fixture.id,
                doctor: response.doctor
              }
            }
          end
        })
      )

    assert_allowed(endpoint_kind)
    assert endpoint_kind.result.doctor.endpoint_kind == :credentialed_remote
    assert endpoint_kind.result.doctor.credential_ok == false

    redacted_host =
      run_eval(
        fixture("provider-doctor-redacted-host-only-001", %{
          run: fn fixture ->
            {:ok, _setting} =
              Settings.put("providers.local_ollama.endpoint_kind", "local_endpoint", %{
                audit?: false
              })

            {:ok, _setting} =
              Settings.put(
                "providers.local_ollama.base_url",
                "http://localhost:11434/v1?token=#{@secret}",
                %{audit?: false}
              )

            expect_local_tags(%{
              "models" => [
                %{"model" => "llama3.2:3b", "context_length" => 8192}
              ]
            })

            {:ok, response} =
              Runner.run(
                "doctor_model_profile",
                %{profile: "local"},
                context(%{req_options: [plug: {Req.Test, __MODULE__}]})
              )

            %{
              decision: :allowed,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                doctor: response.doctor
              }
            }
          end
        })
      )

    assert_allowed(redacted_host)
    assert redacted_host.result.doctor.redacted_host == "localhost"
    assert_no_secret_in(redacted_host, [@secret])
    refute inspect(redacted_host.result.doctor) =~ "/v1"
    refute inspect(redacted_host.result.doctor) =~ "token="
  end

  test "local default model evals distinguish missing and present model state" do
    default_model =
      run_eval(
        fixture("default-model-profile-real-model-001", %{
          run: fn fixture ->
            {:ok, profile} = Settings.resolve_model_profile("local")

            %{
              decision: if(profile.model == "llama3.2:3b", do: :allowed, else: :denied),
              result: profile,
              trace: %{
                fixture_id: fixture.id,
                model: profile.model
              }
            }
          end
        })
      )

    assert_allowed(default_model)
    assert default_model.trace.model == "llama3.2:3b"

    missing =
      run_eval(
        fixture("local-model-missing-remediation-001", %{
          run: fn fixture ->
            expect_local_tags(%{"models" => [%{"model" => "mistral:7b"}]})

            {:ok, response} =
              Runner.run(
                "doctor_model_profile",
                %{profile: "local"},
                context(%{req_options: [plug: {Req.Test, __MODULE__}]})
              )

            %{
              decision: :allowed,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                doctor: response.doctor,
                diagnostic_codes: diagnostic_codes(response)
              }
            }
          end
        })
      )

    assert_allowed(missing)
    assert missing.result.doctor.endpoint_kind == :local_endpoint
    assert missing.result.doctor.endpoint_ok
    assert missing.result.doctor.model_available == false
    assert [%{code: :local_model_missing, message: message}] = missing.result.doctor.diagnostics
    assert message == DoctorDiagnostics.new(:local_model_missing).message

    present =
      run_eval(
        fixture("local-model-present-doctor-pass-001", %{
          run: fn fixture ->
            expect_local_tags(%{
              "models" => [
                %{"model" => "llama3.2:3b", "context_length" => 8192}
              ]
            })

            {:ok, response} =
              Runner.run(
                "doctor_model_profile",
                %{profile: "local"},
                context(%{req_options: [plug: {Req.Test, __MODULE__}]})
              )

            %{
              decision: :allowed,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                doctor: response.doctor
              }
            }
          end
        })
      )

    assert_allowed(present)
    assert present.result.doctor.endpoint_kind == :local_endpoint
    assert present.result.doctor.endpoint_ok
    assert present.result.doctor.model_available
    assert present.result.doctor.context_window == 8192
  end

  defp expect_local_tags(body) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/tags"

      Plug.Conn.send_resp(conn, 200, Jason.encode!(body))
    end)
  end

  defp diagnostic_codes(response), do: Enum.map(response.doctor.diagnostics, & &1.code)

  defp user_setting_keys do
    {:ok, settings} = Settings.read_user_settings()

    settings
    |> flatten_keys()
    |> Enum.sort()
  end

  defp flatten_keys(map), do: flatten_keys(map, [])

  defp flatten_keys(map, prefix) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> flatten_keys(value, prefix ++ [key]) end)
  end

  defp flatten_keys(_value, prefix), do: [Enum.join(prefix, ".")]

  defp put_secret!(secret_ref, secret) do
    assert {:ok, _secret} = Settings.Secrets.put_secret(secret_ref, secret, context())
  end

  defp fixture(id, overrides) do
    id
    |> EvalInventory.row!()
    |> Map.merge(overrides)
  end

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        actor: "local",
        operator_id: "local",
        user_id: "local",
        channel: :test,
        surface: "security_eval"
      },
      overrides
    )
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-onboarding-provider-eval-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
