defmodule AllbertAssist.FirstRun.DisclosureTest do
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Store

  setup do
    original_ollama_base_url = System.get_env("OLLAMA_BASE_URL")

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-disclosure-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:allbert_assist, Paths)
    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:allbert_assist, Paths, previous),
        else: Application.delete_env(:allbert_assist, Paths)

      restore_system_env("OLLAMA_BASE_URL", original_ollama_base_url)
      File.rm_rf!(home)
    end)

    :ok
  end

  test "each surface acknowledges independently and restart does not repeat" do
    :ok = Disclosure.mark_pending(selection(:local))

    assert Disclosure.pending?(:web)
    assert Disclosure.pending?(:tui)
    assert Disclosure.pending?(:cli)

    assert :ok = Disclosure.render_and_ack(:cli, fn text -> send(self(), {:rendered, text}) end)
    assert_receive {:rendered, text}
    assert text =~ "Inference uses your configured local endpoint"
    assert text =~ "allbert admin settings set intent.direct_answer_model_enabled false"
    refute Disclosure.pending?(:cli)
    assert Disclosure.pending?(:web)

    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> flunk("repeated") end)
  end

  test "failed output leaves hosted disclosure pending before transport" do
    :ok = Disclosure.mark_pending(selection(:hosted))

    assert Disclosure.hosted_pending?(:cli)

    assert {:error, {:disclosure_render_failed, RuntimeError}} =
             Disclosure.render_and_ack(:cli, fn _text -> raise "closed output" end)

    assert Disclosure.hosted_pending?(:cli)
    assert Disclosure.text(:cli) =~ "will leave this device for openai"

    assert Disclosure.text(:cli) =~
             "allbert admin settings set intent.direct_answer_model_enabled false"

    assert {:error, {:disclosure_render_failed, :closed}} =
             Disclosure.render_and_ack(:cli, fn _text -> {:error, :closed} end)

    assert Disclosure.hosted_pending?(:cli)
  end

  test "web acknowledgement requires the exact mounted delivery handle" do
    :ok = Disclosure.mark_pending(selection(:hosted))
    assert {:ok, %{text: text, handle: handle}} = Disclosure.prepare_web_delivery()
    assert text =~ "will leave this device"

    assert {:error, :stale_delivery_handle} = Disclosure.acknowledge_web("forged")
    assert Disclosure.hosted_pending?(:web)

    assert :ok = Disclosure.acknowledge_web(handle)
    refute Disclosure.pending?(:web)
  end

  test "same exact route preserves acknowledgement and any route change becomes pending" do
    :ok = Disclosure.mark_pending(selection(:hosted))
    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)
    assert Disclosure.acknowledged_for?(:cli, selection(:hosted))

    assert :ok = Disclosure.reconcile(selection(:hosted))
    refute Disclosure.pending?(:cli)
    assert Disclosure.acknowledged_for?(:cli, selection(:hosted))

    changed_provider = exact_route!("anthropic_fast")
    assert :ok = Disclosure.reconcile(changed_provider)
    assert Disclosure.pending?(:cli)
    refute Disclosure.acknowledged_for?(:cli, selection(:hosted))
    refute Disclosure.acknowledged_for?(:web, changed_provider)
  end

  test "an effective endpoint change invalidates the exact route acknowledgement" do
    System.put_env("OLLAMA_BASE_URL", "http://127.0.0.1:11434/v1")
    assert {:ok, profile} = Settings.resolve_model_profile("direct_answer_local")
    assert {:ok, first_route} = Disclosure.route_for_profile(profile)

    assert first_route.endpoint_class == :local
    assert {:ok, first_endpoint_digest} = Base.decode16(first_route.endpoint_sha256, case: :lower)
    assert byte_size(first_endpoint_digest) == 32
    refute Map.has_key?(first_route, :redacted_host)

    assert :ok = Disclosure.reconcile(first_route)
    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)
    assert Disclosure.acknowledged_for?(:cli, first_route)

    System.put_env("OLLAMA_BASE_URL", "http://127.0.0.1:11435/v1")
    assert {:ok, changed_route} = Disclosure.route_for_profile(profile)
    refute changed_route.endpoint_sha256 == first_route.endpoint_sha256

    assert :ok = Disclosure.reconcile(changed_route)
    assert Disclosure.pending?(:cli)
    refute Disclosure.acknowledged_for?(:cli, first_route)
    refute Disclosure.acknowledged_for?(:cli, changed_route)

    persisted = FirstRun.read_marker() |> get_in(["model_disclosure", "cli"])
    assert inspect(persisted) =~ changed_route.endpoint_sha256
    refute inspect(persisted) =~ "127.0.0.1"
    refute inspect(persisted) =~ "11435"
  end

  test "a full supplied profile binds the endpoint snapshot actually passed to transport" do
    assert {:ok, current_profile} = Settings.resolve_model_profile("fast")
    assert {:ok, current_route} = Disclosure.route_for_profile(current_profile)

    supplied_profile = %{
      current_profile
      | provider_base_url: "https://alternate-openai.example.test/v1"
    }

    assert {:ok, supplied_route} = Disclosure.route_for_profile(supplied_profile)
    assert supplied_route.endpoint_class == :hosted
    refute supplied_route.endpoint_sha256 == current_route.endpoint_sha256

    assert :ok = Disclosure.reconcile(supplied_route)
    persisted = FirstRun.read_marker() |> get_in(["model_disclosure", "cli"])
    assert inspect(persisted) =~ supplied_route.endpoint_sha256
    refute inspect(persisted) =~ "alternate-openai.example.test"
  end

  test "stored routes without endpoint identity are stale and reconcile pending" do
    assert :ok =
             FirstRun.merge_marker(%{
               "model_disclosure" => %{
                 "cli" => %{
                   "state" => "acknowledged",
                   "routes" => [
                     %{
                       "profile" => "fast",
                       "provider" => "openai",
                       "provider_class" => "hosted",
                       "usage" => "primary",
                       "usages" => ["primary"]
                     }
                   ]
                 }
               }
             })

    refute Disclosure.acknowledged_for?(:cli, selection(:hosted))
    assert :ok = Disclosure.reconcile(selection(:hosted))
    assert Disclosure.pending?(:cli)
    refute Disclosure.acknowledged_for?(:cli, selection(:hosted))

    persisted = FirstRun.read_marker() |> get_in(["model_disclosure", "cli"])

    assert [%{"endpoint_class" => "hosted", "endpoint_sha256" => endpoint_sha256}] =
             persisted["routes"]

    assert {:ok, endpoint_digest} = Base.decode16(endpoint_sha256, case: :lower)
    assert byte_size(endpoint_digest) == 32
    refute inspect(persisted) =~ "provider_class"
  end

  test "route evidence persists only endpoint identity and rejects unsafe URL components" do
    profile = %{
      name: "private_hosted",
      provider: "private_provider",
      provider_type: "openai",
      provider_endpoint_kind: "credentialed_remote",
      provider_base_url: "https://private-model.example.test/v1",
      provider_api_key_ref: "vault://private-provider-token",
      api_key: "raw-private-provider-secret",
      prompt: "operator prompt must not persist"
    }

    assert {:ok, route} = Disclosure.route_for_profile(profile)

    assert Map.keys(route) |> Enum.sort() ==
             [:endpoint_class, :endpoint_sha256, :profile, :provider, :usage, :usages]

    assert :ok = Disclosure.reconcile(route)
    persisted = FirstRun.read_marker() |> get_in(["model_disclosure", "cli"])
    persisted_text = inspect(persisted)

    assert persisted_text =~ route.endpoint_sha256
    refute persisted_text =~ "https://"
    refute persisted_text =~ "private-model.example.test"
    refute persisted_text =~ "vault://"
    refute persisted_text =~ "raw-private-provider-secret"
    refute persisted_text =~ "operator prompt must not persist"

    unsafe_profile = %{
      profile
      | name: "unsafe_hosted",
        provider_base_url:
          "https://unsafe-user:unsafe-password@unsafe.example.test/v1?token=unsafe-query#fragment"
    }

    assert {:error, :invalid_effective_model_endpoint} =
             Disclosure.route_for_profile(unsafe_profile)

    persisted_text = FirstRun.read_marker() |> inspect()
    refute persisted_text =~ "unsafe-user"
    refute persisted_text =~ "unsafe-password"
    refute persisted_text =~ "unsafe.example.test"
    refute persisted_text =~ "unsafe-query"
  end

  test "bare acknowledgement grants no route and hosted authority is exact per surface" do
    configure_hosted_direct_answer!()

    assert :ok = Disclosure.acknowledge(:cli)
    refute Disclosure.acknowledged_for?(:cli, selection(:hosted))

    assert :ok = Disclosure.reconcile(selection(:hosted))

    hosted_profile = %{
      name: "fast",
      provider: "openai",
      provider_endpoint_kind: "credentialed_remote"
    }

    local_profile = %{
      name: "local",
      provider: "local_ollama",
      provider_endpoint_kind: "local_endpoint"
    }

    assert {:error,
            {:hosted_disclosure_unavailable,
             %{profile: "fast", provider: "openai", surface: :unknown}}} =
             Disclosure.authorize_transport(hosted_profile, %{
               request: %{
                 channel: :discord,
                 disclosure_surface: :cli,
                 surface: :cli,
                 metadata: %{disclosure_surface: :cli, surface: :cli}
               },
               disclosure_surface: :cli,
               surface: :cli
             })

    assert Disclosure.hosted_pending?(:cli)
    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)

    assert :ok =
             Disclosure.authorize_transport(hosted_profile, %{request: %{channel: :cli}})

    assert {:error,
            {:hosted_disclosure_required, %{profile: "fast", provider: "openai", surface: "web"}}} =
             Disclosure.authorize_transport(hosted_profile, %{request: %{channel: :web}})

    assert :ok =
             Disclosure.authorize_transport(hosted_profile, %{request: %{channel: :discord}})

    assert :ok = Disclosure.authorize_transport(local_profile, %{request: %{channel: :discord}})
  end

  test "fallback disclosure copy names possible egress and a pasteable disable command" do
    assert :ok = Disclosure.reconcile(Map.put(selection(:hosted), :usage, :fallback))
    text = Disclosure.text(:tui)

    assert text =~ "configured DirectAnswer failover"
    assert text =~ "your message may leave this device for openai"

    assert text =~
             "allbert admin settings set models.fallback.allow_local_to_hosted false"
  end

  test "one bounded route-set disclosure acknowledges primary and one fallback" do
    primary = selection(:hosted)

    fallback = %{
      profile: "anthropic_fast",
      provider: "anthropic",
      provider_class: :hosted,
      usage: :fallback
    }

    assert :ok = Disclosure.reconcile_routes([primary, fallback])
    text = Disclosure.text(:cli)
    assert text =~ "configured DirectAnswer route uses fast from openai"
    assert text =~ "configured DirectAnswer failover"
    assert text =~ "anthropic_fast"

    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)
    assert Disclosure.acknowledged_for?(:cli, primary)
    assert Disclosure.acknowledged_for?(:cli, fallback)

    changed = exact_route!("openrouter_fast", :fallback)
    assert :ok = Disclosure.reconcile_routes([primary, changed])
    assert Disclosure.pending?(:cli)
    refute Disclosure.acknowledged_for?(:cli, primary)
    refute Disclosure.acknowledged_for?(:cli, changed)
  end

  test "render acknowledgement is bound to the exact route-set snapshot" do
    assert :ok = Disclosure.reconcile(selection(:hosted))
    changed = exact_route!("anthropic_fast")

    assert {:error, :stale_disclosure_route} =
             Disclosure.render_and_ack(:cli, fn text ->
               assert text =~ "fast"
               assert :ok = Disclosure.reconcile(changed)
             end)

    assert Disclosure.pending?(:cli)
    refute Disclosure.acknowledged_for?(:cli, changed)
  end

  test "web delivery handle cannot acknowledge a concurrently changed route-set" do
    assert :ok = Disclosure.reconcile(selection(:hosted))
    assert {:ok, %{handle: handle}} = Disclosure.prepare_web_delivery()

    changed = exact_route!("anthropic_fast")
    assert :ok = Disclosure.reconcile(changed)

    assert {:error, :stale_delivery_handle} = Disclosure.acknowledge_web(handle)
    assert Disclosure.pending?(:web)
    refute Disclosure.acknowledged_for?(:web, changed)
  end

  test "Settings Central full and dotted writes reconcile route changes" do
    assert {:ok, _settings} =
             Settings.write_user_settings(
               %{
                 "intent" => %{"direct_answer_model_enabled" => true},
                 "model_preferences" => %{"tasks" => %{"direct_answer" => ["fast"]}},
                 "providers" => %{"openai" => %{"enabled" => true}}
               },
               [],
               AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    assert Disclosure.hosted_pending?(:cli)
    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)
    refute Disclosure.pending?(:cli)

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.direct_answer",
               ["local"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert Disclosure.pending?(:cli)
    refute Disclosure.hosted_pending?(:cli)
    assert Disclosure.text(:cli) =~ "Inference uses your configured local endpoint"
  end

  test "a separately configured synthesis route joins the exact bounded disclosure set" do
    assert {:ok, _settings} =
             Settings.write_user_settings(
               %{
                 "intent" => %{"direct_answer_model_enabled" => true},
                 "model_preferences" => %{
                   "tasks" => %{
                     "direct_answer" => ["direct_answer_local"],
                     "fanout_synthesis" => ["fast"]
                   }
                 },
                 "providers" => %{"openai" => %{"enabled" => true}}
               },
               [],
               AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    assert {:ok, routes} = Disclosure.current_model_routes()

    assert Enum.map(routes, &{&1.profile, &1.provider, &1.usage}) == [
             {"direct_answer_local", "local_ollama", :primary},
             {"fast", "openai", :fanout_synthesis}
           ]

    assert Disclosure.hosted_pending?(:cli)
    assert Disclosure.text(:cli) =~ "fan-out report synthesis route uses fast from openai"

    hosted_synthesis = %{
      name: "fast",
      provider: "openai",
      provider_endpoint_kind: "credentialed_remote"
    }

    assert {:error,
            {:hosted_disclosure_required, %{profile: "fast", provider: "openai", surface: "cli"}}} =
             Disclosure.authorize_transport(hosted_synthesis, %{request: %{channel: :cli}})

    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)

    assert :ok =
             Disclosure.authorize_transport(hosted_synthesis, %{request: %{channel: :cli}})

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.fanout_synthesis",
               ["direct_answer_local"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    assert {:ok, [deduped]} = Disclosure.current_model_routes()
    assert deduped.profile == "direct_answer_local"
    assert Disclosure.pending?(:cli)
    refute Disclosure.hosted_pending?(:cli)
  end

  test "one shared hosted route retains every configured model-role usage" do
    assert {:ok, _settings} =
             Settings.write_user_settings(
               %{
                 "intent" => %{"direct_answer_model_enabled" => true},
                 "model_preferences" => %{
                   "tasks" => %{
                     "direct_answer" => ["fast"],
                     "fanout_manager" => ["fast"],
                     "fanout_synthesis" => ["fast"]
                   }
                 },
                 "providers" => %{"openai" => %{"enabled" => true}}
               },
               [],
               AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    assert {:ok, [route]} = Disclosure.current_model_routes()
    assert route.profile == "fast"

    assert route.usages == [:primary, :fanout_manager, :fanout_synthesis]

    text = Disclosure.text(:cli)
    assert text =~ "configured DirectAnswer route uses fast from openai"
    assert text =~ "fan-out manager route uses fast from openai"
    assert text =~ "fan-out report synthesis route uses fast from openai"

    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)
    assert :ok = Disclosure.reconcile_current_direct_answer_route()
    refute Disclosure.pending?(:cli)

    assert :ok =
             Disclosure.authorize_transport(
               %{
                 name: "fast",
                 provider: "openai",
                 provider_endpoint_kind: "credentialed_remote"
               },
               %{request: %{channel: :cli}}
             )
  end

  test "the bounded disclosure set admits four distinct callable routes" do
    assert {:ok, _settings} =
             Settings.write_user_settings(
               %{
                 "intent" => %{"direct_answer_model_enabled" => true},
                 "models" => %{
                   "fallback" => %{
                     "enabled" => true,
                     "allow_local_to_hosted" => true
                   }
                 },
                 "model_preferences" => %{
                   "tasks" => %{
                     "direct_answer" => ["direct_answer_local", "fast"],
                     "fanout_manager" => ["anthropic_fast"],
                     "fanout_synthesis" => ["coding"]
                   }
                 },
                 "providers" => %{
                   "openai" => %{"enabled" => true},
                   "anthropic" => %{"enabled" => true},
                   "openrouter" => %{"enabled" => true},
                   "gemini" => %{"enabled" => true}
                 }
               },
               [],
               AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    assert {:ok, routes} = Disclosure.current_model_routes()

    assert Enum.map(routes, &{&1.profile, &1.usage}) == [
             {"direct_answer_local", :primary},
             {"fast", :fallback},
             {"anthropic_fast", :fanout_manager},
             {"coding", :fanout_synthesis}
           ]
  end

  test "manager and synthesis disclosure copy names role-specific hosted egress" do
    assert {:ok, _settings} =
             Settings.write_user_settings(
               %{
                 "intent" => %{"direct_answer_model_enabled" => true},
                 "model_preferences" => %{
                   "tasks" => %{
                     "direct_answer" => ["direct_answer_local"],
                     "fanout_manager" => ["fast"],
                     "fanout_synthesis" => ["anthropic_fast"]
                   }
                 },
                 "providers" => %{
                   "openai" => %{"enabled" => true},
                   "anthropic" => %{"enabled" => true}
                 }
               },
               [],
               AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    text = Disclosure.text(:cli)

    assert text =~ "fan-out manager route uses fast from openai"
    assert text =~ "Parent objective and planning context may leave this device for openai"
    assert text =~ "model_preferences.tasks.fanout_manager"
    assert text =~ "fan-out report synthesis route uses anthropic_fast from anthropic"
    assert text =~ "Joined child results may leave this device for anthropic"
    assert text =~ "model_preferences.tasks.fanout_synthesis"
  end

  test "manager and synthesis task-chain writes re-pend the exact route set" do
    assert {:ok, _settings} =
             Settings.write_user_settings(
               %{
                 "intent" => %{"direct_answer_model_enabled" => true},
                 "model_preferences" => %{
                   "tasks" => %{
                     "direct_answer" => ["direct_answer_local"],
                     "fanout_manager" => ["fast"],
                     "fanout_synthesis" => ["direct_answer_local"]
                   }
                 },
                 "providers" => %{"openai" => %{"enabled" => true}}
               },
               [],
               AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)
    refute Disclosure.pending?(:cli)

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.fanout_manager",
               ["direct_answer_local"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    assert Disclosure.pending?(:cli)
    refute Disclosure.hosted_pending?(:cli)
    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.fanout_synthesis",
               ["fast"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert Disclosure.pending?(:cli)
    assert Disclosure.hosted_pending?(:cli)
  end

  test "hosted manager and synthesis routes require current exact-set admission" do
    assert {:ok, _settings} =
             Settings.write_user_settings(
               %{
                 "intent" => %{"direct_answer_model_enabled" => true},
                 "model_preferences" => %{
                   "tasks" => %{
                     "direct_answer" => ["direct_answer_local"],
                     "fanout_manager" => ["fast"],
                     "fanout_synthesis" => ["anthropic_fast"]
                   }
                 },
                 "providers" => %{
                   "openai" => %{"enabled" => true},
                   "anthropic" => %{"enabled" => true}
                 }
               },
               [],
               AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    manager = %{
      name: "fast",
      provider: "openai",
      provider_endpoint_kind: "credentialed_remote"
    }

    synthesizer = %{
      name: "anthropic_fast",
      provider: "anthropic",
      provider_endpoint_kind: "credentialed_remote"
    }

    assert {:error,
            {:hosted_disclosure_required, %{profile: "fast", provider: "openai", surface: "cli"}}} =
             Disclosure.authorize_transport(manager, %{request: %{channel: :cli}})

    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)
    assert :ok = Disclosure.authorize_transport(manager, %{request: %{channel: :cli}})
    assert :ok = Disclosure.authorize_transport(synthesizer, %{request: %{channel: :cli}})

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.fanout_synthesis",
               ["direct_answer_local"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    assert {:error,
            {:hosted_route_not_current,
             %{profile: "anthropic_fast", provider: "anthropic", surface: "cli"}}} =
             Disclosure.authorize_transport(synthesizer, %{request: %{channel: :cli}})
  end

  test "onboarding reset preserves independent disclosure authority" do
    assert :ok = Disclosure.reconcile(selection(:hosted))
    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)

    assert :ok =
             FirstRun.merge_marker(%{
               "onboarding_complete" => true,
               "profile_reviewed" => true,
               "wizard_started" => true,
               "track" => "direct",
               "wizard_step" => "first_chat",
               "wizard_done" => ["welcome"],
               "wizard_direct_entry" => true,
               "applied_persona" => "operator",
               "model_answers_declined" => true,
               "model_reenable_offered" => true,
               "objective_reconciled_v063" => true,
               "independent_runtime_state" => %{"keep" => true}
             })

    assert :ok = FirstRun.reset_onboarding()
    marker = FirstRun.read_marker()

    refute Map.has_key?(marker, "onboarding_complete")
    refute Map.has_key?(marker, "profile_reviewed")
    refute Map.has_key?(marker, "wizard_started")
    refute Map.has_key?(marker, "track")
    refute Map.has_key?(marker, "wizard_step")
    refute Map.has_key?(marker, "wizard_done")
    refute Map.has_key?(marker, "wizard_direct_entry")
    refute Map.has_key?(marker, "applied_persona")
    refute Map.has_key?(marker, "model_answers_declined")
    refute Map.has_key?(marker, "model_reenable_offered")
    refute Map.has_key?(marker, "objective_reconciled_v063")
    assert marker["independent_runtime_state"] == %{"keep" => true}
    assert Disclosure.acknowledged_for?(:cli, selection(:hosted))
  end

  defp selection(:local) do
    %{profile: "local", provider: "local_ollama", provider_class: :local}
  end

  defp selection(:hosted) do
    %{profile: "fast", provider: "openai", provider_class: :hosted}
  end

  defp configure_hosted_direct_answer! do
    assert {:ok, _settings} =
             Store.write_user_settings(%{
               "intent" => %{"direct_answer_model_enabled" => true},
               "model_preferences" => %{"tasks" => %{"direct_answer" => ["fast"]}},
               "providers" => %{"openai" => %{"enabled" => true}}
             })
  end

  defp exact_route!(profile_name, usage \\ :primary) do
    {:ok, profile} = Settings.resolve_model_profile(profile_name)
    {:ok, route} = Disclosure.route_for_profile(profile)
    %{route | usage: usage, usages: [usage]}
  end

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
