defmodule AllbertAssist.Settings.StoreCompositionRaceTest do
  # v1.0.2 M8.3 item 1: regression proof for the settings-composition TOCTOU
  # race root-caused in M8.2. `Store.resolved_settings/0` (and the write paths)
  # used to read the Fragments persistent_term composition cache several times
  # per call — defaults for the merge, schema for validation, fragments for the
  # version contract. An async registration-signal invalidation landing between
  # two reads handed one call two DIFFERENT compositions, so validation failed
  # with `{:error, {:unknown_setting, _}}` against a transiently partial
  # registry (SurfacePolicy then degraded to its default policy — the
  # list_channels_test solo flake). These tests swap the cached composition
  # deterministically between reads via the Fragments read-hook seam and assert
  # each Store entry point still resolves against ONE composition snapshot.
  #
  # Owns the settings-root app env for the test; also swaps the shared
  # persistent_term composition cache (restored via clear_cache) and seeds the
  # notes_files descriptors (ProviderPreconditions) — the checker's primary-lane
  # adjudication for this mix is app_env_serial (the gate_test precedent).
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.TestSupport.ProviderPreconditions

  @app_key "apps.notes_files.notes_root"
  @cache_key {Fragments, :default_composition}
  @read_hook_key {Fragments, :composition_read_hook}

  setup do
    ProviderPreconditions.ensure_notes_files_descriptors!()

    settings_root =
      Path.join(
        System.tmp_dir!(),
        "allbert-composition-race-#{System.pid()}-#{System.unique_integer([:positive])}"
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
      case previous_settings_env do
        nil -> Application.delete_env(:allbert_assist, AllbertAssist.Settings)
        env -> Application.put_env(:allbert_assist, AllbertAssist.Settings, env)
      end

      File.rm_rf!(settings_root)
      Fragments.clear_cache()
    end)

    {:ok, settings_root: settings_root}
  end

  test "resolved_settings survives a composition swap between its reads",
       %{settings_root: settings_root} do
    notes_root = seed_user_app_setting!(settings_root)
    partial = partial_composition!()

    swap_composition_after_first_read!(partial)
    result = Store.resolved_settings()
    Process.delete(@read_hook_key)

    assert {:ok, merged, user_settings} = result
    assert get_in(merged, ["apps", "notes_files", "notes_root"]) == notes_root
    assert get_in(user_settings, ["apps", "notes_files", "notes_root"]) == notes_root
  end

  test "write_user_settings survives a composition swap between its reads",
       %{settings_root: settings_root} do
    notes_root = Path.join(settings_root, "notes")
    partial = partial_composition!()

    swap_composition_after_first_read!(partial)

    result =
      Store.write_user_settings(%{
        "apps" => %{"notes_files" => %{"notes_root" => notes_root}}
      })

    Process.delete(@read_hook_key)

    assert {:ok, written} = result
    assert get_in(written, ["apps", "notes_files", "notes_root"]) == notes_root
  end

  test "put_user_setting survives a composition swap between its reads",
       %{settings_root: settings_root} do
    seed_user_app_setting!(settings_root)
    updated_root = Path.join(settings_root, "notes-updated")
    partial = partial_composition!()

    swap_composition_after_first_read!(partial)
    result = Store.put_user_setting(@app_key, updated_root, %{audit?: false})
    Process.delete(@read_hook_key)

    assert {:ok, merged, user_settings, _diagnostics} = result
    assert get_in(merged, ["apps", "notes_files", "notes_root"]) == updated_root
    assert get_in(user_settings, ["apps", "notes_files", "notes_root"]) == updated_root
  end

  defp seed_user_app_setting!(settings_root) do
    notes_root = Path.join(settings_root, "notes")

    assert {:ok, _settings} =
             Store.write_user_settings(%{
               "apps" => %{"notes_files" => %{"notes_root" => notes_root}}
             })

    notes_root
  end

  # Build a composition that is genuinely missing the key under test — the shape
  # a mid-invalidation rebuild sees while the composition is transiently partial.
  # Precondition-asserted: the full composition knows the app key, this one does
  # not, so a Store call that re-read the cache between its reads would validate
  # against a composition without the key and fail with `{:error,
  # {:unknown_setting, _}}` — the exact M8.2 symptom.
  #
  # v1.4 M13.1 derives the partial composition from the full one by subtraction.
  # It used to build one from EMPTY private registries and detect partialness
  # through a key only the registries contributed, which decayed twice as
  # extraction progressed: M9 moved notes_files settings to the pack, so the app
  # key itself was no longer absent, and M13 extracted the last plugin, so NO key
  # is registry-sourced any more. Measured at M13.1, the full and empty-registry
  # compositions are byte-identical at 624 keys — the swap had become a no-op and
  # the regression proof silently proved nothing. Subtracting the key under test
  # restores the original guarantee and does not care where a fragment comes
  # from, so the next extraction cannot quietly disarm it again.
  defp partial_composition!, do: partial_composition!(@app_key)

  defp partial_composition!(app_key) do
    full = %{
      fragments: Fragments.registered_fragments(),
      schema: Fragments.schema(),
      defaults: Fragments.defaults(),
      safe_write_keys: Fragments.safe_write_keys()
    }

    assert Map.has_key?(full.schema, app_key)

    partial = %{
      full
      | schema: Map.delete(full.schema, app_key),
        safe_write_keys: List.delete(full.safe_write_keys, app_key)
    }

    refute Map.has_key?(partial.schema, app_key)
    refute app_key in partial.safe_write_keys

    partial
  end

  # Install the Fragments read hook: the first default-composition read (the
  # snapshot read on fixed code) sees the full registry; every later unpinned
  # read sees the swapped-in partial composition. On the pre-fix double-read
  # code this deterministically reproduces the async-invalidation interleave.
  defp swap_composition_after_first_read!(partial) do
    counter = :counters.new(1, [])

    Process.put(@read_hook_key, fn ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) >= 2 do
        :persistent_term.put(@cache_key, partial)
      end
    end)
  end
end
