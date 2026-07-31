defmodule AllbertAssist.Intent.Router.DescriptorResolverTest do
  @moduledoc "v0.54 M9.3a — layered descriptor resolution."
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Extensions.Registry, as: ExtensionsRegistry
  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Intent.Router.DescriptorStore
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

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

  test "stored layers inherit an omitted canonical policy and honor an explicit policy" do
    with_descriptor_home(fn ->
      attrs = %{
        app_id: :allbert,
        action_name: "append_memory",
        label: "Operator memory wording",
        examples: ["remember this detail"],
        synonyms: ["remember"],
        required_slots: [:memory],
        slot_extractors: %{memory: :memory_phrase}
      }

      assert {:ok, _path} = DescriptorStore.put(:generated, attrs)
      assert resolved_policy("append_memory") == :explicit_evidence

      assert {:ok, _path} = DescriptorStore.put(:overrides, attrs)
      assert resolved_policy("append_memory") == :explicit_evidence

      assert {:ok, _path} =
               DescriptorStore.put(:overrides, Map.put(attrs, :selection_policy, :semantic))

      assert resolved_policy("append_memory") == :semantic
    end)
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

    test "deterministic eval includes gated descriptors but honors operator disables" do
      original_home = System.get_env("ALLBERT_HOME")
      original_paths = Application.get_env(:allbert_assist, Paths)
      original_settings = Application.get_env(:allbert_assist, Settings)

      home =
        Path.join(
          System.tmp_dir!(),
          "allbert-descriptor-eval-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      System.put_env("ALLBERT_HOME", home)
      Application.delete_env(:allbert_assist, Paths)
      Application.delete_env(:allbert_assist, Settings)

      on_exit(fn ->
        File.rm_rf!(home)

        if original_home,
          do: System.put_env("ALLBERT_HOME", original_home),
          else: System.delete_env("ALLBERT_HOME")

        restore(Paths, original_paths)
        restore(Settings, original_settings)
      end)

      eval_opts = [availability: :deterministic_eval]
      keys = resolved_keys(DescriptorResolver.resolve(eval_opts))
      assert MapSet.member?(keys, {:stocksage, "run_analysis"})

      assert {:ok, _path} =
               DescriptorStore.put(:overrides, %{
                 app_id: :stocksage,
                 action_name: "run_analysis",
                 disabled: true
               })

      keys = resolved_keys(DescriptorResolver.resolve(eval_opts))
      refute MapSet.member?(keys, {:stocksage, "run_analysis"})
    end
  end

  defp resolved_keys(descriptors), do: MapSet.new(descriptors, &{&1.app_id, &1.action_name})

  defp resolved_policy(action_name) do
    DescriptorResolver.resolve(ignore_disabled?: true)
    |> Enum.find(&(&1.app_id == :allbert and &1.action_name == action_name))
    |> Map.fetch!(:selection_policy)
  end

  defp with_descriptor_home(fun) do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-descriptor-layers-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    try do
      fun.()
    after
      File.rm_rf!(home)

      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      restore(Paths, original_paths)
      restore(Settings, original_settings)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore(key, value), do: Application.put_env(:allbert_assist, key, value)
end
