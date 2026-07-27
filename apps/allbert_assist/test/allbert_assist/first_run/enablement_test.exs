defmodule AllbertAssist.FirstRun.EnablementTest do
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.FirstRun.{Disclosure, Enablement}
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.Audit
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

      assert {:ok, result} =
               Enablement.reconcile(model_state,
                 settings: settings(),
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

  test "raw explicit hosted primary overrides automatic local-first selection and disclosure" do
    System.put_env("OPENAI_API_KEY", "operator-env-key")
    user = %{"model_preferences" => %{"primary" => "fast"}}
    assert {:ok, _settings} = Store.write_user_settings(user)
    assert {:ok, resolved, persisted_user} = Store.resolved_settings()

    assert {:ok, %{state: :auto_enabled, selection: selection}} =
             Enablement.reconcile(:local_ready,
               settings: resolved,
               user_settings: persisted_user,
               local_selection: @local,
               context: %{audit?: false}
             )

    assert selection == @hosted
    assert {:ok, persisted} = Store.read_user_settings()
    assert get_in(persisted, ["model_preferences", "primary"]) == "fast"
    assert get_in(persisted, ["intent", "direct_answer_model_enabled"]) == true
    assert Disclosure.hosted_pending?(:web)
    assert Disclosure.text(:web) =~ "selected fast from openai"
    assert Disclosure.text(:web) =~ "will leave this device"
  end

  test "an unavailable raw primary prevents mismatched enablement and disclosure" do
    user = %{"model_preferences" => %{"primary" => "coding_local"}}
    assert {:ok, _settings} = Store.write_user_settings(user)
    assert {:ok, resolved, persisted_user} = Store.resolved_settings()

    assert {:ok, %{state: :enabled_unavailable, selection: nil}} =
             Enablement.reconcile(:local_ready,
               settings: resolved,
               user_settings: persisted_user,
               local_selection: @local,
               hosted_selection: nil,
               context: %{audit?: false}
             )

    assert {:ok, persisted} = Store.read_user_settings()
    assert get_in(persisted, ["model_preferences", "primary"]) == "coding_local"
    assert get_in(persisted, ["intent", "direct_answer_model_enabled"]) == nil
    refute Disclosure.pending?(:web)
    refute Disclosure.pending?(:tui)
    refute Disclosure.pending?(:cli)
  end

  test "a primary change between selection and the Store lock aborts enablement" do
    assert {:ok, %{state: :enabled_unavailable, selection: nil, provenance: provenance}} =
             Enablement.reconcile(:local_ready,
               settings: settings(),
               user_settings: %{},
               local_selection: @local,
               before_write: fn ->
                 assert {:ok, _merged, _user, _diagnostics} =
                          Store.put_user_setting("model_preferences.primary", "fast", %{
                            audit?: false
                          })
               end,
               context: %{audit?: false}
             )

    assert provenance.disposition == :selection_changed
    assert provenance.written == []
    assert {:ok, persisted} = Store.read_user_settings()
    assert get_in(persisted, ["model_preferences", "primary"]) == "fast"
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
    refute Disclosure.pending?(:web)
  end

  test "a concurrent explicit enable keeps the matching hosted disclosure pending" do
    assert {:ok, %{state: :auto_enabled, selection: @hosted, provenance: provenance}} =
             Enablement.reconcile(:runtime_missing,
               settings: settings(),
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
               hosted_selection: nil
             )
  end

  test "unusable local plus configured hosted presence never invokes a local or hosted probe" do
    caller = self()

    assert {:ok, %{state: :auto_enabled, selection: %{provider_class: :hosted}}} =
             Enablement.reconcile(:model_missing,
               settings: settings(),
               user_settings: %{},
               doctor: fn _profile -> send(caller, :probe_called) end,
               context: %{audit?: false}
             )

    refute_receive :probe_called
  end

  test "raw explicit provider false blocks an env-provided hosted key without writes" do
    System.put_env("ALLBERT_VAULT_BACKEND", "env")
    System.put_env("OPENAI_API_KEY", "operator-env-key")

    assert {:ok, _settings} =
             Store.write_user_settings(%{
               "providers" => %{"openai" => %{"enabled" => false}}
             })

    assert {:ok, settings, user_settings} = Store.resolved_settings()

    assert {:ok, %{state: :nothing_detected, selection: nil}} =
             Enablement.reconcile(:byok_ready,
               settings: settings,
               user_settings: user_settings,
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
               settings: settings(),
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
  defp expected_state(:byok_ready, false), do: :nothing_detected
  defp expected_state(:below_hardware_floor, false), do: :below_floor
  defp expected_state(_state, false), do: :needs_model
  defp expected_state(_state, true), do: :auto_enabled

  defp expected_provider_class(:local_ready, _hosted?), do: :local
  defp expected_provider_class(_state, true), do: :hosted
  defp expected_provider_class(_state, false), do: nil

  defp provider_class(%{selection: nil}), do: nil
  defp provider_class(%{selection: selection}), do: selection.provider_class

  defp settings do
    %{
      "intent" => %{
        "direct_answer_model_enabled" => false,
        "model_assist_enabled" => false
      },
      "model_preferences" => %{
        "primary" => "local",
        "tasks" => %{"direct_answer" => ["local", "fast"]}
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
end
