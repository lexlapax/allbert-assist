defmodule AllbertAssist.Settings.StoreTurnSnapshotTest do
  # v1.0.2 M8.4: contract for the turn-scoped resolved-settings snapshot.
  # `Store.resolved_settings/0` runs a full disk-read + version contract +
  # deep merge + full-schema validation pass (~44-48ms measured in M8.3) on
  # EVERY call; an intent turn makes many such reads. `with_resolved_settings/1`
  # pins ONE resolution to the calling process for the duration of the fun
  # (inside a `Fragments.with_composition` pin so composition and resolution
  # cannot tear). Semantics proven here, red-first against the pre-fix
  # per-read behavior:
  #   * one resolution serves all reads inside the pin;
  #   * a write by THIS process inside the pin refreshes the pin
  #     (intra-turn read-your-own-write preserved);
  #   * a write by ANOTHER process during the pin lands NEXT turn (today it
  #     lands mid-turn nondeterministically — the pin is strictly more
  #     deterministic);
  #   * nested pins are reentrant and keep the outer snapshot.
  #
  # Owns the settings-root app env for the test (the composition-race test's
  # app_env_serial precedent).
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.SurfacePolicy

  @key "intent.handoff_threshold"
  @default_value 0.6
  @written_value 0.9
  @resolution_hook_key {Store, :resolution_hook}

  setup do
    settings_root =
      Path.join(
        System.tmp_dir!(),
        "allbert-turn-snapshot-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(settings_root)

    previous_settings_env = Application.get_env(:allbert_assist, AllbertAssist.Settings)

    Application.put_env(
      :allbert_assist,
      AllbertAssist.Settings,
      Keyword.put(previous_settings_env || [], :root, settings_root)
    )

    Fragments.clear_cache()

    on_exit(fn ->
      Process.delete(@resolution_hook_key)

      case previous_settings_env do
        nil -> Application.delete_env(:allbert_assist, AllbertAssist.Settings)
        env -> Application.put_env(:allbert_assist, AllbertAssist.Settings, env)
      end

      File.rm_rf!(settings_root)
      Fragments.clear_cache()
    end)

    :ok
  end

  test "with_resolved_settings serves many reads from ONE resolution" do
    counter = install_resolution_counter()

    Store.with_resolved_settings(fn ->
      for _read <- 1..5 do
        assert {:ok, merged, _user_settings} = Store.resolved_settings()
        assert get_in(merged, ["intent", "handoff_threshold"]) == @default_value
      end
    end)

    assert :counters.get(counter, 1) == 1
  end

  test "unpinned reads still resolve on every call (no global cache)" do
    counter = install_resolution_counter()

    for _read <- 1..3 do
      assert {:ok, _merged, _user_settings} = Store.resolved_settings()
    end

    assert :counters.get(counter, 1) == 3
  end

  test "a write by this process inside the pin refreshes the snapshot (read-your-own-write)" do
    Store.with_resolved_settings(fn ->
      assert {:ok, merged, _user_settings} = Store.resolved_settings()
      assert get_in(merged, ["intent", "handoff_threshold"]) == @default_value

      assert {:ok, _merged, _user_settings, _diagnostics} =
               Store.put_user_setting(@key, @written_value, %{audit?: false})

      assert {:ok, merged, user_settings} = Store.resolved_settings()
      assert get_in(merged, ["intent", "handoff_threshold"]) == @written_value
      assert get_in(user_settings, ["intent", "handoff_threshold"]) == @written_value
    end)
  end

  test "another process's write during the pin is visible only after the pin exits" do
    Store.with_resolved_settings(fn ->
      assert {:ok, merged, _user_settings} = Store.resolved_settings()
      assert get_in(merged, ["intent", "handoff_threshold"]) == @default_value

      put_from_another_process!()

      assert {:ok, merged, _user_settings} = Store.resolved_settings()

      assert get_in(merged, ["intent", "handoff_threshold"]) == @default_value,
             "a concurrent other-process write leaked into the pinned turn"
    end)

    assert {:ok, merged, _user_settings} = Store.resolved_settings()
    assert get_in(merged, ["intent", "handoff_threshold"]) == @written_value
  end

  test "nested pins are reentrant and keep the outer snapshot" do
    counter = install_resolution_counter()

    Store.with_resolved_settings(fn ->
      put_from_another_process!()

      Store.with_resolved_settings(fn ->
        assert {:ok, merged, _user_settings} = Store.resolved_settings()

        assert get_in(merged, ["intent", "handoff_threshold"]) == @default_value,
               "a nested pin re-resolved instead of keeping the outer snapshot"
      end)
    end)

    assert :counters.get(counter, 1) == 1
  end

  test "SurfacePolicy.report_policy resolves settings exactly once per evaluation" do
    counter = install_resolution_counter()

    policy = SurfacePolicy.report_policy("list_channels", %{}, %{surface_id: "cli"})

    assert policy.render_mode == :assistant_summary
    assert :counters.get(counter, 1) == 1
  end

  defp install_resolution_counter do
    counter = :counters.new(1, [])
    Process.put(@resolution_hook_key, fn -> :counters.add(counter, 1, 1) end)
    counter
  end

  # The write runs in a separate process, so the caller's pin (and the
  # caller's resolution-hook counter) are not involved.
  defp put_from_another_process! do
    task =
      Task.async(fn ->
        Store.put_user_setting(@key, @written_value, %{audit?: false})
      end)

    assert {:ok, _merged, _user_settings, _diagnostics} = Task.await(task)
  end
end
