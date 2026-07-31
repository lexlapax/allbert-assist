defmodule AllbertAssist.FirstRun.DisclosureTest do
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Store

  setup do
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

    changed_provider = %{profile: "fast", provider: "anthropic", provider_class: :hosted}
    assert :ok = Disclosure.reconcile(changed_provider)
    assert Disclosure.pending?(:cli)
    refute Disclosure.acknowledged_for?(:cli, selection(:hosted))
    refute Disclosure.acknowledged_for?(:web, changed_provider)
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

    changed = %{fallback | provider: "openrouter"}
    assert :ok = Disclosure.reconcile_routes([primary, changed])
    assert Disclosure.pending?(:cli)
    refute Disclosure.acknowledged_for?(:cli, primary)
    refute Disclosure.acknowledged_for?(:cli, changed)
  end

  test "render acknowledgement is bound to the exact route-set snapshot" do
    assert :ok = Disclosure.reconcile(selection(:hosted))
    changed = %{profile: "other", provider: "anthropic", provider_class: :hosted}

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

    changed = %{profile: "other", provider: "anthropic", provider_class: :hosted}
    assert :ok = Disclosure.reconcile(changed)

    assert {:error, :stale_delivery_handle} = Disclosure.acknowledge_web(handle)
    assert Disclosure.pending?(:web)
    refute Disclosure.acknowledged_for?(:web, changed)
  end

  test "Settings Central full and dotted writes reconcile route changes" do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "intent" => %{"direct_answer_model_enabled" => true},
               "model_preferences" => %{"tasks" => %{"direct_answer" => ["fast"]}},
               "providers" => %{"openai" => %{"enabled" => true}}
             })

    assert Disclosure.hosted_pending?(:cli)
    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)
    refute Disclosure.pending?(:cli)

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", ["local"], %{audit?: false})

    assert Disclosure.pending?(:cli)
    refute Disclosure.hosted_pending?(:cli)
    assert Disclosure.text(:cli) =~ "Inference uses your configured local endpoint"
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
end
