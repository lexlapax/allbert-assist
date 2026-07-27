defmodule AllbertAssist.FirstRun.EnablementTest do
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.FirstRun.Enablement
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
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-enablement-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:allbert_assist, AllbertAssist.Settings)
    Application.put_env(:allbert_assist, AllbertAssist.Settings, root: root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:allbert_assist, AllbertAssist.Settings, previous),
        else: Application.delete_env(:allbert_assist, AllbertAssist.Settings)

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
