defmodule AllbertAssist.FirstRun.EnablementTest do
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.FirstRun.{Disclosure, Enablement}
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.Audit
  alias AllbertAssist.Settings.Models
  alias AllbertAssist.Settings.Store

  @states [
    :local_ready,
    :runtime_missing,
    :runtime_unhealthy,
    :model_missing,
    :below_hardware_floor,
    :byok_ready
  ]

  @provider_env_vars ~w(
    ALLBERT_VAULT_BACKEND
    ANTHROPIC_API_KEY
    OPENAI_API_KEY
    OPENROUTER_API_KEY
    GOOGLE_API_KEY
    GEMINI_API_KEY
  )

  @local %{
    profile: "local",
    provider: "local_ollama",
    provider_class: :local,
    verification: :doctor_healthy
  }
  @hosted %{
    profile: "fast",
    provider: "openai",
    provider_class: :hosted,
    verification: :configured_unverified
  }

  setup do
    original_env = Map.new(@provider_env_vars, &{&1, System.get_env(&1)})

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-enablement-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:allbert_assist, AllbertAssist.Settings)
    previous_paths = Application.get_env(:allbert_assist, Paths)
    Application.put_env(:allbert_assist, AllbertAssist.Settings, root: root)
    Application.put_env(:allbert_assist, Paths, home: root)
    Enum.each(@provider_env_vars, &System.delete_env/1)
    System.put_env("ALLBERT_VAULT_BACKEND", "env")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:allbert_assist, AllbertAssist.Settings, previous),
        else: Application.delete_env(:allbert_assist, AllbertAssist.Settings)

      if previous_paths,
        do: Application.put_env(:allbert_assist, Paths, previous_paths),
        else: Application.delete_env(:allbert_assist, Paths)

      Enum.each(original_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(root)
    end)

    :ok
  end

  test "all twelve model-state by hosted-presence cells match the binding projection" do
    for model_state <- @states, hosted? <- [false, true] do
      File.rm_rf!(Store.root())

      local = if model_state == :local_ready, do: @local
      hosted = if hosted?, do: @hosted

      cell_settings =
        if hosted? and model_state != :local_ready, do: settings(["fast"]), else: settings()

      assert {:ok, result} =
               Enablement.reconcile(model_state,
                 settings: cell_settings,
                 user_settings: %{},
                 local_selection: local,
                 hosted_selection: hosted,
                 context: %{audit?: false}
               )

      assert result.state == expected_state(model_state, hosted?)
      assert provider_class(result) == expected_provider_class(model_state, hosted?)
    end
  end

  test "raw explicit false short-circuits every cell and writes nothing" do
    user = %{"intent" => %{"direct_answer_model_enabled" => false}}

    for model_state <- @states do
      assert {:ok, %{state: :sticky_disabled, selection: nil}} =
               Enablement.reconcile(model_state,
                 settings: settings(),
                 user_settings: user,
                 local_selection: @local,
                 hosted_selection: @hosted
               )
    end

    assert {:ok, %{}} = Store.read_user_settings()
  end

  test "sticky-disabled preview still reports selected task availability without writes" do
    user = %{"intent" => %{"direct_answer_model_enabled" => false}}

    assert {:ok,
            %{
              state: :sticky_disabled,
              availability: :available,
              selection: @local
            }} =
             Enablement.preview(:model_missing,
               settings: settings(),
               user_settings: user,
               local_selection: @local
             )

    assert {:ok,
            %{
              state: :sticky_disabled,
              availability: :unavailable,
              selection: nil
            }} =
             Enablement.preview(:local_ready,
               settings: settings(),
               user_settings: user,
               local_selection: nil,
               hosted_selection: nil
             )

    assert {:ok, %{}} = Store.read_user_settings()
  end

  test "presentation preview projects a usable model without settings or disclosure writes" do
    assert {:ok, %{state: :auto_enabled, selection: @local, provenance: nil}} =
             Enablement.preview(:local_ready,
               settings: settings(),
               user_settings: %{},
               local_selection: @local
             )

    assert {:ok, %{}} = Store.read_user_settings()
    refute Disclosure.pending?(:web)
    refute Disclosure.pending?(:tui)
    refute Disclosure.pending?(:cli)
  end

  test "raw explicit hosted direct-answer preference binds selection and disclosure" do
    System.put_env("OPENAI_API_KEY", "operator-env-key")
    user = %{"model_preferences" => %{"tasks" => %{"direct_answer" => ["fast"]}}}
    assert {:ok, _settings} = Store.write_user_settings(user)
    assert {:ok, resolved, persisted_user} = Store.resolved_settings()

    assert {:ok, %{state: :auto_enabled, selection: selection}} =
             Enablement.reconcile(:local_ready,
               settings: resolved,
               user_settings: persisted_user,
               local_selection: nil,
               hosted_selection: @hosted,
               context: %{audit?: false}
             )

    assert selection == @hosted
    assert {:ok, persisted} = Store.read_user_settings()
    assert get_in(persisted, ["model_preferences", "primary"]) == nil
    assert get_in(persisted, ["model_preferences", "tasks", "direct_answer"]) == ["fast"]
    assert get_in(persisted, ["intent", "direct_answer_model_enabled"]) == true
    assert Disclosure.hosted_pending?(:web)
    assert Disclosure.text(:web) =~ "configured DirectAnswer route uses fast from openai"
    assert Disclosure.text(:web) =~ "will leave this device"
  end

  test "an unavailable raw direct-answer preference prevents mismatched enablement" do
    user = %{
      "model_preferences" => %{"tasks" => %{"direct_answer" => ["coding_local"]}}
    }

    assert {:ok, _settings} = Store.write_user_settings(user)
    assert {:ok, resolved, persisted_user} = Store.resolved_settings()

    assert {:ok, %{state: :enabled_unavailable, selection: nil}} =
             Enablement.reconcile(:local_ready,
               settings: resolved,
               user_settings: persisted_user,
               local_selection: nil,
               hosted_selection: nil,
               context: %{audit?: false}
             )

    assert {:ok, persisted} = Store.read_user_settings()
    assert get_in(persisted, ["model_preferences", "primary"]) == nil

    assert get_in(persisted, ["model_preferences", "tasks", "direct_answer"]) == [
             "coding_local"
           ]

    assert get_in(persisted, ["intent", "direct_answer_model_enabled"]) == nil
    refute Disclosure.pending?(:web)
    refute Disclosure.pending?(:tui)
    refute Disclosure.pending?(:cli)
  end

  test "global 3B readiness cannot satisfy the default qualified DirectAnswer task" do
    caller = self()

    doctor = fn profile ->
      send(caller, {:doctor, profile})

      {:ok,
       %{
         endpoint_ok: true,
         model_available: profile == "local",
         endpoint_kind: :local_endpoint
       }}
    end

    assert {:ok, %{state: :enabled_unavailable, selection: nil}} =
             Enablement.reconcile(:local_ready,
               settings: qualified_settings(),
               user_settings: %{},
               doctor: doctor,
               tags: [],
               context: %{audit?: false}
             )

    assert_receive {:doctor, "direct_answer_local"}
    refute_receive {:doctor, "local"}
    assert {:ok, %{}} = Store.read_user_settings()
  end

  test "qualified Qwen readiness enables DirectAnswer without changing global primary" do
    assert {:ok, %{state: :auto_enabled, selection: selection}} =
             Enablement.reconcile(:model_missing,
               settings: qualified_settings(),
               user_settings: %{},
               doctor: fn "direct_answer_local" ->
                 {:ok, %{endpoint_ok: true, model_available: true}}
               end,
               context: %{audit?: false}
             )

    assert selection.profile == "direct_answer_local"

    assert {:ok, persisted} = Store.read_user_settings()
    assert get_in(persisted, ["model_preferences", "primary"]) == nil

    assert get_in(persisted, ["model_preferences", "tasks", "direct_answer"]) == [
             "direct_answer_local"
           ]
  end

  test "an already-enabled qualified task remains ready when the global 3B is absent" do
    user_settings = %{"intent" => %{"direct_answer_model_enabled" => true}}

    assert {:ok, %{state: :auto_enabled, selection: selection, provenance: nil}} =
             Enablement.reconcile(:model_missing,
               settings: qualified_settings(),
               user_settings: user_settings,
               doctor: fn "direct_answer_local" ->
                 {:ok, %{endpoint_ok: true, model_available: true}}
               end
             )

    assert selection.profile == "direct_answer_local"
  end

  test "an explicit empty task keeps primary compatibility without rewriting the task" do
    user_settings = %{"model_preferences" => %{"tasks" => %{"direct_answer" => []}}}
    assert {:ok, _settings} = Store.write_user_settings(user_settings)

    settings =
      qualified_settings()
      |> put_in(["model_preferences", "tasks", "direct_answer"], [])

    local = %{@local | profile: "local"}

    assert {:ok, %{state: :auto_enabled, selection: ^local}} =
             Enablement.reconcile(:local_ready,
               settings: settings,
               user_settings: user_settings,
               local_selection: local,
               context: %{audit?: false}
             )

    assert {:ok, persisted} = Store.read_user_settings()
    assert get_in(persisted, ["model_preferences", "tasks", "direct_answer"]) == []
    assert get_in(persisted, ["model_preferences", "primary"]) == nil
    assert get_in(persisted, ["intent", "direct_answer_model_enabled"]) == true
  end

  test "a direct-answer selection change between selection and Store lock aborts enablement" do
    assert {:ok, %{state: :enabled_unavailable, selection: nil, provenance: provenance}} =
             Enablement.reconcile(:local_ready,
               settings: settings(),
               user_settings: %{},
               local_selection: @local,
               before_write: fn ->
                 assert {:ok, _merged, _user, _diagnostics} =
                          Store.put_user_setting(
                            "model_preferences.tasks.direct_answer",
                            ["fast"],
                            %{audit?: false}
                          )
               end,
               context: %{audit?: false}
             )

    assert provenance.disposition == :selection_changed
    assert provenance.written == []
    assert {:ok, persisted} = Store.read_user_settings()
    assert get_in(persisted, ["model_preferences", "primary"]) == nil
    assert get_in(persisted, ["model_preferences", "tasks", "direct_answer"]) == ["fast"]
    assert get_in(persisted, ["intent", "direct_answer_model_enabled"]) == nil
    refute Disclosure.pending?(:web)
  end

  test "an explicit disable between selection and the Store lock wins without partial writes" do
    assert {:ok, %{state: :sticky_disabled, selection: nil, provenance: provenance}} =
             Enablement.reconcile(:local_ready,
               settings: settings(),
               user_settings: %{},
               local_selection: @local,
               before_write: fn ->
                 assert {:ok, _merged, _user, _diagnostics} =
                          Store.put_user_setting(
                            "intent.direct_answer_model_enabled",
                            false,
                            %{audit?: false}
                          )
               end,
               context: %{audit?: false}
             )

    assert provenance.disposition == :explicitly_disabled
    assert provenance.written == []
    assert {:ok, persisted} = Store.read_user_settings()
    assert get_in(persisted, ["intent", "direct_answer_model_enabled"]) == false
    assert get_in(persisted, ["intent", "model_assist_enabled"]) == nil
    assert get_in(persisted, ["model_preferences", "primary"]) == nil
    assert get_in(persisted, ["model_preferences", "tasks", "direct_answer"]) == nil
    refute Disclosure.pending?(:web)
  end

  test "a concurrent explicit enable keeps the matching hosted disclosure pending" do
    assert {:ok, %{state: :auto_enabled, selection: @hosted, provenance: provenance}} =
             Enablement.reconcile(:runtime_missing,
               settings: settings(["fast"]),
               user_settings: %{},
               hosted_selection: @hosted,
               before_write: fn ->
                 assert {:ok, _merged, _user, _diagnostics} =
                          Store.put_user_setting(
                            "intent.direct_answer_model_enabled",
                            true,
                            %{audit?: false}
                          )
               end,
               context: %{audit?: false}
             )

    assert provenance.disposition == :applied
    refute "intent.direct_answer_model_enabled" in provenance.written
    assert Disclosure.hosted_pending?(:web)
    assert Disclosure.text(:web) =~ "will leave this device"
  end

  test "enabled but currently unusable projects enabled_unavailable" do
    user = %{"intent" => %{"direct_answer_model_enabled" => true}}

    assert {:ok, %{state: :enabled_unavailable}} =
             Enablement.reconcile(:runtime_unhealthy,
               settings: settings(),
               user_settings: user,
               local_selection: nil,
               hosted_selection: nil
             )
  end

  test "unrelated hosted presence cannot escape the direct-answer task chain" do
    caller = self()

    assert {:ok, %{state: :needs_model, selection: nil}} =
             Enablement.reconcile(:model_missing,
               settings: settings(),
               user_settings: %{},
               doctor: fn profile -> send(caller, {:probe_called, profile}) end,
               tags: [],
               context: %{audit?: false}
             )

    assert_receive {:probe_called, "local"}
  end

  test "raw explicit provider false blocks an env-provided hosted key without writes" do
    System.put_env("ALLBERT_VAULT_BACKEND", "env")
    System.put_env("OPENAI_API_KEY", "operator-env-key")

    assert {:ok, _settings} =
             Store.write_user_settings(%{
               "providers" => %{"openai" => %{"enabled" => false}}
             })

    assert {:ok, settings, user_settings} = Store.resolved_settings()

    assert {:ok, %{state: :enabled_unavailable, selection: nil}} =
             Enablement.reconcile(:byok_ready,
               settings: settings,
               user_settings: user_settings,
               local_selection: nil,
               context: %{audit?: false}
             )

    assert {:ok, persisted} = Store.read_user_settings()
    assert get_in(persisted, ["providers", "openai", "enabled"]) == false
    assert get_in(persisted, ["intent", "direct_answer_model_enabled"]) == nil
  end

  test "double boot and later wizard/persona-style writes remain idempotent" do
    opts = [
      settings: settings(),
      user_settings: %{},
      local_selection: @local,
      hosted_selection: nil,
      context: %{audit?: false}
    ]

    assert {:ok, %{state: :auto_enabled, provenance: %{written: written}}} =
             Enablement.reconcile(:local_ready, opts)

    assert length(written) == 3
    assert {:ok, user} = Store.read_user_settings()
    assert get_in(user, ["model_preferences", "primary"]) == nil

    assert get_in(user, ["model_preferences", "tasks", "direct_answer"]) == [
             "local",
             "fast"
           ]

    assert {:ok, %{state: :auto_enabled, provenance: nil}} =
             Enablement.reconcile(:local_ready,
               settings: settings(),
               user_settings: user,
               local_selection: @local
             )

    assert {:ok, _merged, _user, _diagnostics} =
             Store.put_user_setting("intent.model_assist_enabled", true, %{audit?: false})

    assert {:ok, after_wizard} = Store.read_user_settings()
    assert after_wizard == user
  end

  test "boot reconciliation preserves one acknowledgement for an exact local-to-hosted route set" do
    assert {:ok, _settings} =
             Store.write_user_settings(%{
               "intent" => %{"direct_answer_model_enabled" => true},
               "model_preferences" => %{
                 "tasks" => %{"direct_answer" => ["local", "fast"]}
               },
               "models" => %{
                 "fallback" => %{
                   "enabled" => true,
                   "allow_local_to_hosted" => true
                 }
               },
               "providers" => %{"openai" => %{"enabled" => true}}
             })

    assert {:ok, resolved, user_settings} = Store.resolved_settings()

    assert {:ok, %{state: :auto_enabled, selection: @local}} =
             Enablement.reconcile(:local_ready,
               settings: resolved,
               user_settings: user_settings,
               local_selection: @local,
               context: %{audit?: false}
             )

    assert Disclosure.pending?(:cli)
    disclosure = Disclosure.text(:cli)
    assert disclosure =~ "configured DirectAnswer route uses local"
    assert disclosure =~ "configured DirectAnswer failover"
    assert disclosure =~ "fast from openai"
    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)

    assert {:ok, [local, hosted]} = Models.candidates_for(:direct_answer)
    assert :ok = Disclosure.authorize_transport(local.profile, %{request: %{channel: :cli}})
    assert :ok = Disclosure.authorize_transport(hosted.profile, %{request: %{channel: :cli}})

    assert {:ok, restarted_settings, restarted_user_settings} = Store.resolved_settings()

    assert {:ok, %{state: :auto_enabled, selection: @local}} =
             Enablement.reconcile(:local_ready,
               settings: restarted_settings,
               user_settings: restarted_user_settings,
               local_selection: @local,
               context: %{audit?: false}
             )

    refute Disclosure.pending?(:cli)
    assert :ok = Disclosure.authorize_transport(hosted.profile, %{request: %{channel: :cli}})
  end

  test "boot detection defers without a Req application and does not write" do
    assert {:deferred, :req_not_started} =
             Enablement.reconcile_on_boot(:local_ready,
               req_started?: fn -> false end,
               settings: settings(),
               user_settings: %{},
               local_selection: @local
             )

    assert {:ok, %{}} = Store.read_user_settings()
  end

  test "FirstRun boot entry projects an injected fresh-process probe" do
    assert {:ok, %{state: :auto_enabled, selection: %{provider_class: :local}}} =
             FirstRun.reconcile_enablement(
               model_state: :local_ready,
               req_started?: fn -> true end,
               settings: settings(),
               user_settings: %{},
               local_selection: @local,
               context: %{audit?: false}
             )
  end

  test "audit provenance records the actual detected selection" do
    assert {:ok, %{state: :auto_enabled}} =
             Enablement.reconcile(:runtime_missing,
               settings: settings(["fast"]),
               user_settings: %{},
               hosted_selection: @hosted
             )

    audit = File.read!(Audit.audit_path())
    assert audit =~ "enabled_by: detection"
    assert audit =~ "profile: fast"
    assert audit =~ "provider: openai"
    assert audit =~ "provider_class: hosted"
  end

  defp expected_state(:local_ready, _hosted?), do: :auto_enabled
  defp expected_state(:runtime_missing, false), do: :nothing_detected
  defp expected_state(:byok_ready, false), do: :enabled_unavailable
  defp expected_state(:below_hardware_floor, false), do: :below_floor
  defp expected_state(_state, false), do: :needs_model
  defp expected_state(_state, true), do: :auto_enabled

  defp expected_provider_class(:local_ready, _hosted?), do: :local
  defp expected_provider_class(_state, true), do: :hosted
  defp expected_provider_class(_state, false), do: nil

  defp provider_class(%{selection: nil}), do: nil
  defp provider_class(%{selection: selection}), do: selection.provider_class

  defp settings(direct_answer_profiles \\ ["local", "fast"]) do
    %{
      "intent" => %{
        "direct_answer_model_enabled" => false,
        "model_assist_enabled" => false
      },
      "model_preferences" => %{
        "primary" => "local",
        "tasks" => %{"direct_answer" => direct_answer_profiles}
      },
      "providers" => %{
        "local_ollama" => %{
          "enabled" => true,
          "endpoint_kind" => "local_endpoint",
          "type" => "openai_compatible"
        },
        "openai" => %{
          "enabled" => true,
          "endpoint_kind" => "credentialed_remote",
          "credential_status" => :configured,
          "type" => "openai"
        }
      },
      "model_profiles" => %{
        "local" => %{
          "provider" => "local_ollama",
          "model" => "llama3.2:3b",
          "capabilities" => ["text_generation"]
        },
        "fast" => %{
          "provider" => "openai",
          "model" => "gpt-4o-mini",
          "capabilities" => ["text_generation"]
        }
      }
    }
  end

  defp qualified_settings do
    %{
      "model_preferences" => %{
        "primary" => "local",
        "tasks" => %{"direct_answer" => ["direct_answer_local"]}
      },
      "providers" => %{
        "local_ollama" => %{
          "enabled" => true,
          "endpoint_kind" => "local_endpoint",
          "type" => "openai_compatible"
        }
      },
      "model_profiles" => %{
        "local" => %{
          "provider" => "local_ollama",
          "model" => "llama3.2:3b",
          "capabilities" => ["text_generation"]
        },
        "direct_answer_local" => %{
          "provider" => "local_ollama",
          "model" => "qwen2.5:7b",
          "capabilities" => ["text_generation"]
        }
      }
    }
  end
end
