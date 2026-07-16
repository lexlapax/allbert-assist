defmodule AllbertAssist.Intent.Router.DescriptorResolverTest do
  @moduledoc "v0.54 M9.3a — layered descriptor resolution."
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Extensions.Registry, as: ExtensionsRegistry
  alias AllbertAssist.Intent.Router.DescriptorResolver

  test "resolve/0 dedups by {app_id, action_name}" do
    resolved = DescriptorResolver.resolve()
    keys = Enum.map(resolved, &{&1.app_id, &1.action_name})
    assert length(keys) == length(Enum.uniq(keys))
  end

  test "resolve/0 is a superset of the app/plugin descriptor layer" do
    resolved_keys =
      DescriptorResolver.resolve() |> MapSet.new(&{&1.app_id, &1.action_name})

    app_plugin_keys =
      ExtensionsRegistry.registered_intent_descriptors()
      |> MapSet.new(&{&1.app_id, &1.action_name})

    assert MapSet.subset?(app_plugin_keys, resolved_keys)
    # the M9.1 core descriptors resolve under the reserved :allbert id
    assert MapSet.member?(resolved_keys, {:allbert, "append_memory"})
  end

  test "resolve/0 includes M10 outbound action-module slot descriptors" do
    descriptor =
      DescriptorResolver.resolve()
      |> Enum.find(&(&1.app_id == :allbert and &1.action_name == "send_email"))

    assert descriptor.source == :action
    assert descriptor.required_slots == [:to, :body]
    assert descriptor.slot_extractors.to == :email_address
    assert descriptor.slot_extractors.body == :message_body_phrase
  end

  describe "v0.63 F5 production gates (capability-off + demo intents)" do
    setup do
      # The suite bypasses the gates globally; turn the bypass OFF to exercise the real
      # production behavior a fresh install sees.
      saved = Application.get_env(:allbert_assist, :intent_descriptor_include_all)
      Application.put_env(:allbert_assist, :intent_descriptor_include_all, false)

      on_exit(fn ->
        Application.put_env(:allbert_assist, :intent_descriptor_include_all, saved)
      end)

      :ok
    end

    test "demo/example intents (StockSage) are not routable by default" do
      keys = resolved_keys(DescriptorResolver.resolve())
      refute MapSet.member?(keys, {:stocksage, "run_analysis"})
    end

    test "capability-gated intents (voice) are excluded when the capability is off (default)" do
      actions = DescriptorResolver.resolve() |> Enum.map(& &1.action_name)
      refute "synthesize_voice" in actions
    end

    test "ignore_disabled?: true bypasses the gates (the eval path sees everything)" do
      keys = resolved_keys(DescriptorResolver.resolve(ignore_disabled?: true))
      assert MapSet.member?(keys, {:stocksage, "run_analysis"})
    end
  end

  defp resolved_keys(descriptors), do: MapSet.new(descriptors, &{&1.app_id, &1.action_name})
end
