defmodule AllbertAssist.Settings.StoreTuiIdentityBootstrapTest do
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.TUI, as: TUIPlugin
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Audit
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.TestSupport.ShippedRegistries

  @identity_key "channels.tui.identity_map"
  @enabled_key "channels.tui.enabled"
  @default_mapping [
    %{
      "external_user_id" => "default",
      "user_id" => "local",
      "enabled" => true
    }
  ]
  # v1.3 M9.b.12.d — auto-enablement writes the task-scoped DirectAnswer chain,
  # not the global primary. M9.b.3 narrowed @auto_enablement_keys to match, so a
  # fixture naming "model_preferences.primary" is now refused outright with
  # :settings_if_absent_keys_not_allowed and this row stopped exercising the
  # serialization it is named for. The key is the fixture's; the contract under
  # test — that a concurrent identity bootstrap loses none of these — is
  # unchanged.
  @enablement_values %{
    "intent.direct_answer_model_enabled" => true,
    "intent.model_assist_enabled" => true,
    "model_preferences.tasks.direct_answer" => ["local"]
  }

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-tui-identity-bootstrap-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_audit = Application.get_env(:allbert_assist, Audit)

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    PluginRegistry.clear()
    assert {:ok, "allbert.tui"} = PluginRegistry.register_module(TUIPlugin)
    Fragments.clear_cache()

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Settings, original_settings)
      restore_env(Audit, original_audit)
      ShippedRegistries.restore!()
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "writes the exact default local mapping once and audits one bootstrap" do
    context = bootstrap_context()

    assert {:ok,
            %{
              disposition: :bootstrapped,
              written: [@enabled_key, @identity_key]
            }} = Store.prepare_local_tui_launch(context)

    assert {:ok, user_settings} = Store.read_user_settings()
    assert get_in(user_settings, ["channels", "tui", "enabled"])
    assert get_in(user_settings, ["channels", "tui", "identity_map"]) == @default_mapping

    assert {:ok,
            %{
              disposition: :present,
              written: [],
              present: %{
                @enabled_key => true,
                @identity_key => @default_mapping
              }
            }} = Store.prepare_local_tui_launch(context)

    audit = File.read!(Audit.audit_path())
    assert audit =~ "actor: first-run-local-tui-bootstrap"
    assert audit =~ "- old: absent"

    assert length(Regex.scan(~r/^## .* channels\.tui\.enabled$/m, audit)) == 1
    assert length(Regex.scan(~r/^## .* channels\.tui\.identity_map$/m, audit)) == 1
    assert length(Regex.scan(~r/^## .* settings\.transaction$/m, audit)) == 1
  end

  test "preserves every raw-present identity map without merging default" do
    maps = [
      [],
      [%{"external_user_id" => "work", "user_id" => "alice", "enabled" => true}],
      [%{"external_user_id" => "default", "user_id" => "local", "enabled" => false}]
    ]

    for identity_map <- maps do
      reset_store!()
      put!(@identity_key, identity_map)

      assert {:ok,
              %{
                disposition: :activated,
                written: [@enabled_key],
                present: %{@identity_key => ^identity_map}
              }} = Store.prepare_local_tui_launch(bootstrap_context())

      assert {:ok, user_settings} = Store.read_user_settings()
      assert get_in(user_settings, ["channels", "tui", "enabled"])
      assert get_in(user_settings, ["channels", "tui", "identity_map"]) == identity_map
    end
  end

  test "activates but does not invent identity for a custom effective profile" do
    put!("channels.tui.profile", "work")

    assert {:ok, %{disposition: :activated, written: [@enabled_key]}} =
             Store.prepare_local_tui_launch(Map.put(bootstrap_context(), :profile, "work"))

    assert {:ok, user_settings} = Store.read_user_settings()
    assert get_in(user_settings, ["channels", "tui", "enabled"])
    assert is_nil(get_in(user_settings, ["channels", "tui", "identity_map"]))

    assert {:ok, %{disposition: :custom_profile, written: []}} =
             Store.prepare_local_tui_launch(Map.put(bootstrap_context(), :profile, "work"))
  end

  test "an explicitly disabled TUI blocks launch preparation without rewriting it" do
    put!("channels.tui.enabled", false)

    assert {:ok,
            %{
              disposition: :explicitly_disabled,
              written: [],
              present: %{@enabled_key => false}
            }} = Store.prepare_local_tui_launch(bootstrap_context())

    assert {:ok, user_settings} = Store.read_user_settings()
    refute get_in(user_settings, ["channels", "tui", "enabled"])
    assert is_nil(get_in(user_settings, ["channels", "tui", "identity_map"]))
  end

  test "effective launcher profile overrides the stored profile for bootstrap admission" do
    put!("channels.tui.profile", "default")
    put!(@enabled_key, true)

    assert {:ok, %{disposition: :custom_profile, written: []}} =
             Store.prepare_local_tui_launch(bootstrap_context() |> Map.put(:profile, "work"))

    assert {:ok, user_settings} = Store.read_user_settings()
    assert is_nil(get_in(user_settings, ["channels", "tui", "identity_map"]))
  end

  test "blank and explicit default profiles retain built-in bootstrap semantics" do
    for profile <- ["", "default"] do
      reset_store!()
      put!("channels.tui.profile", profile)

      assert {:ok, %{disposition: :bootstrapped}} =
               Store.prepare_local_tui_launch(Map.put(bootstrap_context(), :profile, profile))

      assert {:ok, user_settings} = Store.read_user_settings()
      assert get_in(user_settings, ["channels", "tui", "enabled"])
      assert get_in(user_settings, ["channels", "tui", "identity_map"]) == @default_mapping
    end
  end

  test "concurrent first launches converge on one mapping and one audit row" do
    results =
      1..12
      |> Task.async_stream(
        fn _ -> Store.prepare_local_tui_launch(bootstrap_context()) end,
        ordered: false,
        max_concurrency: 12,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # v1.3 M9.b.12.d — this row asserted a *timing* property on top of the
    # convergence property it is named for. StoreLock.with_lock/2 gives up after
    # 5s, and twelve racers against one exclusive SQLite lock do not all get
    # through that budget on a loaded machine: reproduced under CPU load as
    # %{{:error, {:settings_lock_timeout, "database is locked"}} => 9,
    #   {:ok, :bootstrapped} => 1, {:ok, :present} => 2}.
    #
    # A bounded lock timeout is designed behaviour and twelve simultaneous first
    # launches is not a real scenario, so the timeout is not the defect — the
    # assertion was. What must hold under any interleaving is convergence: one
    # bootstrap, one audit row, and no torn write. That is asserted here, and
    # convergence of the resulting state is then proven deterministically below
    # rather than inferred from how many racers won a lock race.
    tally = Enum.frequencies_by(results, &result_shape/1)

    assert Enum.count(results, &match?({:ok, %{disposition: :bootstrapped}}, &1)) == 1,
           "expected exactly one bootstrap; got #{inspect(tally)}"

    refute Enum.any?(results, &match?({:ok, %{disposition: :activated}}, &1)),
           "no launch may see the enabled flag without the identity map — that is a torn " <>
             "write of the bootstrap subset; got #{inspect(tally)}"

    for result <- results do
      case result do
        {:ok, %{disposition: disposition}} ->
          assert disposition in [:bootstrapped, :present],
                 "unexpected disposition #{inspect(disposition)}; got #{inspect(tally)}"

        {:error, {:settings_lock_timeout, _reason}} ->
          :ok

        other ->
          flunk("only a lock timeout may fail a concurrent launch, got #{inspect(other)}")
      end
    end

    audit = File.read!(Audit.audit_path())
    assert length(Regex.scan(~r/^## .* channels\.tui\.identity_map$/m, audit)) == 1

    # Deterministic convergence: once the burst has settled, every further
    # launch observes the one mapping and writes nothing more. This is the
    # guarantee the row exists for, and it does not depend on lock contention.
    for _ <- 1..3 do
      assert {:ok, %{disposition: :present, written: []}} =
               Store.prepare_local_tui_launch(bootstrap_context())
    end

    assert {:ok, user_settings} = Store.read_user_settings()
    assert get_in(user_settings, ["channels", "tui", "identity_map"]) == @default_mapping

    assert length(
             Regex.scan(~r/^## .* channels\.tui\.identity_map$/m, File.read!(Audit.audit_path()))
           ) ==
             1
  end

  test "surfaces an audit append failure in bootstrap diagnostics" do
    Application.put_env(:allbert_assist, Audit,
      writer: fn _path, _content -> {:error, :eacces} end
    )

    assert {:ok, %{disposition: :bootstrapped, diagnostics: diagnostics}} =
             Store.prepare_local_tui_launch(bootstrap_context())

    assert length(diagnostics) == 3
    assert Enum.all?(diagnostics, &(&1.source == :settings_audit))
    assert Enum.all?(diagnostics, &(&1.error =~ "audit_write_failed"))
    assert Enum.all?(diagnostics, &(&1.error =~ "eacces"))
    assert {:ok, user_settings} = Store.read_user_settings()
    assert get_in(user_settings, ["channels", "tui", "enabled"])
    assert get_in(user_settings, ["channels", "tui", "identity_map"]) == @default_mapping
  end

  test "identity bootstrap and model enablement serialize without losing keys" do
    caller = self()

    identity =
      Task.async(fn ->
        send(caller, {:ready, self()})
        receive do: (:go -> Store.prepare_local_tui_launch(bootstrap_context()))
      end)

    enablement =
      Task.async(fn ->
        send(caller, {:ready, self()})

        receive do: (:go ->
                       Store.put_user_settings_if_absent(@enablement_values, %{audit?: false}))
      end)

    assert_receive {:ready, identity_pid}
    assert_receive {:ready, enablement_pid}
    send(identity_pid, :go)
    send(enablement_pid, :go)

    assert match?({:ok, _}, Task.await(identity))
    assert match?({:ok, _}, Task.await(enablement))
    assert {:ok, user_settings} = Store.read_user_settings()
    assert get_in(user_settings, ["channels", "tui", "enabled"])
    assert get_in(user_settings, ["channels", "tui", "identity_map"]) == @default_mapping
    assert get_in(user_settings, ["intent", "direct_answer_model_enabled"])
    assert get_in(user_settings, ["intent", "model_assist_enabled"])
    assert get_in(user_settings, ["model_preferences", "tasks", "direct_answer"]) == ["local"]
  end

  test "a concurrent explicit map is the final authority" do
    caller = self()
    custom = [%{"external_user_id" => "default", "user_id" => "alice", "enabled" => true}]

    bootstrap =
      Task.async(fn ->
        send(caller, {:ready, self()})
        receive do: (:go -> Store.prepare_local_tui_launch(%{audit?: false}))
      end)

    explicit =
      Task.async(fn ->
        send(caller, {:ready, self()})
        receive do: (:go -> Store.put_user_setting(@identity_key, custom, %{audit?: false}))
      end)

    assert_receive {:ready, bootstrap_pid}
    assert_receive {:ready, explicit_pid}
    send(bootstrap_pid, :go)
    send(explicit_pid, :go)

    assert match?({:ok, _}, Task.await(bootstrap))
    assert match?({:ok, _, _, _}, Task.await(explicit))
    assert {:ok, user_settings} = Store.read_user_settings()
    assert get_in(user_settings, ["channels", "tui", "identity_map"]) == custom
  end

  test "a concurrent explicit disable is the final launch authority" do
    for _attempt <- 1..10 do
      reset_store!()
      caller = self()

      bootstrap =
        Task.async(fn ->
          send(caller, {:ready, self()})

          receive do
            :go -> Store.prepare_local_tui_launch(%{audit?: false, profile: "default"})
          end
        end)

      disable =
        Task.async(fn ->
          send(caller, {:ready, self()})

          receive do
            :go -> Store.put_user_setting(@enabled_key, false, %{audit?: false})
          end
        end)

      assert_receive {:ready, bootstrap_pid}
      assert_receive {:ready, disable_pid}
      send(bootstrap_pid, :go)
      send(disable_pid, :go)

      assert match?({:ok, _}, Task.await(bootstrap))
      assert match?({:ok, _, _, _}, Task.await(disable))
      assert {:ok, user_settings} = Store.read_user_settings()
      refute get_in(user_settings, ["channels", "tui", "enabled"])

      assert {:ok, %{disposition: :explicitly_disabled, written: []}} =
               Store.prepare_local_tui_launch(%{audit?: false, profile: "default"})
    end
  end

  defp result_shape({:ok, %{disposition: disposition}}), do: {:ok, disposition}
  defp result_shape({:error, reason}), do: {:error, reason}
  defp result_shape(other), do: {:other, other}

  defp bootstrap_context do
    %{actor: "first-run-local-tui-bootstrap", channel: "tui", profile: "default"}
  end

  defp put!(key, value) do
    assert {:ok, _merged, _user, _diagnostics} =
             Store.put_user_setting(key, value, %{audit?: false})
  end

  defp reset_store!, do: File.rm_rf!(Store.root())

  defp restore_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
