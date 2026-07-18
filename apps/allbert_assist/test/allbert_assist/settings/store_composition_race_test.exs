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
  # global registries (ProviderPreconditions / ShippedRegistries.restore!) —
  # the checker's primary-lane adjudication for this mix is app_env_serial
  # (the gate_test precedent).
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.TestSupport.ProviderPreconditions
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures
  alias AllbertAssist.TestSupport.ShippedRegistries

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
      ShippedRegistries.restore!()
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

  # Build a core-only composition from empty private registries — the shape a
  # mid-invalidation rebuild sees while the global registry is transiently
  # partial. Precondition-asserted: the full composition knows the app key,
  # the partial one does not.
  defp partial_composition!, do: partial_composition!(@app_key)

  defp partial_composition!(app_key) do
    context = RegistryIsolationFixtures.start_isolated_registries(:composition_race)

    partial = %{
      fragments: Fragments.registered_fragments(context),
      schema: Fragments.schema(context),
      defaults: Fragments.defaults(context),
      safe_write_keys: Fragments.safe_write_keys(context)
    }

    assert Map.has_key?(Fragments.schema(), app_key)
    refute Map.has_key?(partial.schema, app_key)
    refute Map.has_key?(partial.defaults, "apps")

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
