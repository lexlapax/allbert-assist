defmodule AllbertAssist.Settings.Store do
  @moduledoc false

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.Audit
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Settings.StoreLock
  alias AllbertAssist.Settings.VersionContract
  alias AllbertAssist.Settings.YamlCodec

  @app :allbert_assist

  # v1.0.2 M8.4: process-scoped turn snapshot (see with_resolved_settings/1).
  @resolved_pin_key {__MODULE__, :pinned_resolved_settings}
  @resolution_hook_key {__MODULE__, :resolution_hook}
  @auto_enablement_keys MapSet.new([
                          "intent.direct_answer_model_enabled",
                          "intent.model_assist_enabled",
                          "model_preferences.primary"
                        ])
  @tui_identity_key "channels.tui.identity_map"
  @tui_profile_key "channels.tui.profile"
  @tui_enabled_key "channels.tui.enabled"
  @default_tui_identity_map [
    %{
      "external_user_id" => "default",
      "user_id" => "local",
      "enabled" => true
    }
  ]

  def root, do: Paths.settings_root()

  def settings_path, do: Path.join(root(), "settings.yml")

  def ensure_root! do
    root = root()
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, "audit"))
    root
  end

  def read_user_settings do
    path = settings_path()

    if File.exists?(path) do
      with {:ok, settings} <- YamlCodec.read_file(path) do
        {:ok, normalize_user_settings(settings)}
      end
    else
      {:ok, %{}}
    end
  end

  # The read-merge-validate passes below read the schema composition several
  # times (version contract, defaults merge, validation). Each runs under ONE
  # `Fragments.with_composition/1` snapshot so an async registration-signal
  # cache invalidation landing mid-call can never hand one pass two different
  # compositions (v1.0.2 M8.3; the pre-existing TOCTOU race root-caused in
  # M8.2 — transiently partial registries made validation fail with
  # `{:error, {:unknown_setting, _}}`).
  def write_user_settings(settings, opts \\ []) when is_map(settings) and is_list(opts) do
    settings = normalize_user_settings(settings)

    StoreLock.with_lock(root(), fn -> write_user_settings_locked(settings) end)
  rescue
    exception ->
      {:error, {:settings_write_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  # v1.0.2 M8.4: reads inside a `with_resolved_settings/1` pin are served from
  # the process-scoped snapshot; unpinned reads resolve per call exactly as
  # before (no global cache). Full ADR 0031 validation still runs on every
  # actual resolution — the pin only reuses a validated result within one turn.
  def resolved_settings do
    case Process.get(@resolved_pin_key) do
      nil -> resolve_settings()
      pinned -> pinned
    end
  end

  @doc """
  Run `fun` with ONE resolved-settings snapshot pinned to the calling process.

  The turn-scoped settings snapshot (v1.0.2 M8.4, mirroring
  `Fragments.with_composition/1`): every `Settings.get` runs the full
  disk-read + version-contract + deep-merge + full-schema-validate pass
  (~44-48ms measured in M8.3) and an intent turn makes dozens of reads.
  This pin resolves ONCE — inside a `Fragments.with_composition/1` pin, so
  the composition and the resolution cannot tear — and serves every
  `resolved_settings/0` call within `fun` from the snapshot.

  Semantics (regression-tested red-first in StoreTurnSnapshotTest):

    * Reentrant — a nested pin keeps the outer snapshot.
    * A write by THIS process inside the pin (`put_user_setting/3` /
      `write_user_settings/2`) refreshes the pin, so intra-turn
      read-your-own-write is preserved.
    * A write by ANOTHER process during the pin lands on the NEXT turn.
      Today such writes land mid-turn nondeterministically (each read races
      the writer), so the pin is strictly more deterministic.
    * If the eager resolution fails, nothing is pinned and every read inside
      `fun` re-resolves — exactly today's error behavior.

  Pin one turn (or one policy evaluation), never a long-lived process.
  """
  @spec with_resolved_settings((-> result)) :: result when result: term()
  def with_resolved_settings(fun) when is_function(fun, 0) do
    case Process.get(@resolved_pin_key) do
      nil -> pin_resolved_settings(fun)
      _pinned -> fun.()
    end
  end

  defp pin_resolved_settings(fun) do
    Fragments.with_composition(fn ->
      case resolve_settings() do
        {:ok, _merged, _user_settings} = resolved ->
          Process.put(@resolved_pin_key, resolved)

          try do
            fun.()
          after
            Process.delete(@resolved_pin_key)
          end

        _error ->
          fun.()
      end
    end)
  end

  # A successful write inside a pin must not leave the turn reading a stale
  # snapshot: re-resolve (under the same pinned composition) and re-pin. If
  # the refresh fails, drop the pin so later reads fall back to live
  # resolution rather than a wrong snapshot.
  defp refresh_resolved_pin do
    if Process.get(@resolved_pin_key) != nil do
      case resolve_settings() do
        {:ok, _merged, _user_settings} = resolved -> Process.put(@resolved_pin_key, resolved)
        _error -> Process.delete(@resolved_pin_key)
      end
    end

    :ok
  end

  defp resolve_settings do
    Fragments.with_composition(fn ->
      resolution_hook()

      with {:ok, user_settings} <- read_user_settings(),
           :ok <- VersionContract.reject_forward_versions(user_settings),
           {:ok, merged} <- merge_user_settings(user_settings),
           :ok <- Schema.validate_settings(merged) do
        {:ok, merged, user_settings}
      end
    end)
  end

  # Test-only seam (v1.0.2 M8.4, mirroring the M8.3 Fragments read hook):
  # fires once per ACTUAL disk read-merge-validate resolution pass — never on
  # a pinned snapshot read — so tests can count resolutions per turn.
  # Production processes never set the hook.
  defp resolution_hook do
    case Process.get(@resolution_hook_key) do
      nil -> :ok
      fun when is_function(fun, 0) -> fun.()
    end
  end

  def put_user_setting(key, value, context \\ %{}) do
    StoreLock.with_lock(root(), fn ->
      Fragments.with_composition(fn -> put_user_setting_snapshotted(key, value, context) end)
    end)
  end

  @doc """
  Atomically writes the raw-absent subset of the first-run enablement keys.

  Stored values, including `false`, are preserved. The closed key set keeps
  this system-initiated write from becoming a general settings bypass.
  """
  def put_user_settings_if_absent(values, context)
      when is_map(values) and is_map(context) do
    with :ok <- validate_auto_enablement_keys(values) do
      StoreLock.with_lock(root(), fn -> put_user_settings_if_absent_locked(values, context) end)
    end
  end

  def put_user_settings_if_absent(_values, _context),
    do: {:error, {:invalid_settings_if_absent, :expected_maps}}

  @doc """
  Atomically prepares Settings for an explicit local interactive TUI launch.

  This exact-purpose launcher primitive is deliberately separate from the
  closed three-key first-run model-enablement write. It activates the TUI when
  activation is raw-absent and seeds the built-in identity only for the default
  effective profile. Explicit `false` and every raw-present identity map are
  preserved.
  """
  def prepare_local_tui_launch(context) when is_map(context) do
    StoreLock.with_lock(root(), fn ->
      Fragments.with_composition(fn ->
        prepare_local_tui_launch_snapshotted(context)
      end)
    end)
  end

  def prepare_local_tui_launch(_context),
    do: {:error, {:invalid_local_tui_launch_bootstrap, :expected_context_map}}

  defp put_user_settings_if_absent_locked(values, context) do
    Fragments.with_composition(fn ->
      put_user_settings_if_absent_snapshotted(values, context)
    end)
  end

  defp prepare_local_tui_launch_snapshotted(context) do
    with {:ok, user_settings} <- read_user_settings(),
         :ok <- VersionContract.reject_forward_versions(user_settings),
         {:ok, merged} <- merge_user_settings(user_settings),
         :ok <- Schema.validate_settings(merged) do
      case Schema.get_dotted(user_settings, @tui_enabled_key) do
        false ->
          tui_launch_result(:explicitly_disabled, [], %{@tui_enabled_key => false})

        _not_explicitly_disabled ->
          maybe_write_local_tui_launch_defaults(user_settings, merged, context)
      end
    end
  end

  defp maybe_write_local_tui_launch_defaults(user_settings, merged, context) do
    effective_profile =
      Map.get(
        context,
        :profile,
        Map.get(context, "profile", Schema.get_dotted(merged, @tui_profile_key))
      )

    desired =
      if normalize_tui_profile(effective_profile) == "default" do
        %{
          @tui_enabled_key => true,
          @tui_identity_key => @default_tui_identity_map
        }
      else
        %{@tui_enabled_key => true}
      end

    {applied, preserved} = partition_absent_values(desired, user_settings)
    updated_user_settings = put_dotted_values(user_settings, applied)
    updated_merged = put_dotted_values(merged, applied)

    with :ok <- Schema.validate_settings(updated_merged),
         {:ok, _settings} <- write_absent_subset(updated_user_settings, applied) do
      diagnostics = audit_local_tui_launch(applied, preserved, context)

      refresh_resolved_pin()

      tui_launch_result(
        tui_launch_disposition(applied, effective_profile),
        applied |> Map.keys() |> Enum.sort(),
        preserved,
        diagnostics
      )
    end
  end

  defp tui_launch_disposition(applied, _profile) when is_map_key(applied, @tui_identity_key),
    do: :bootstrapped

  defp tui_launch_disposition(applied, _profile) when map_size(applied) > 0, do: :activated

  defp tui_launch_disposition(_applied, profile) do
    if normalize_tui_profile(profile) == "default", do: :present, else: :custom_profile
  end

  defp audit_local_tui_launch(applied, _preserved, _context) when map_size(applied) == 0,
    do: []

  defp audit_local_tui_launch(_applied, _preserved, %{audit?: false}), do: []
  defp audit_local_tui_launch(_applied, _preserved, %{"audit?" => false}), do: []

  defp audit_local_tui_launch(applied, preserved, context) do
    setting_diagnostics =
      applied
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {key, value} -> audit_write(key, :absent, value, context) end)

    transaction_diagnostics =
      case Audit.append_settings_transaction(Map.keys(applied) |> Enum.sort(), preserved, context) do
        {:ok, path} -> [%{source: :settings_audit, audit_path: path}]
        {:error, reason} -> [%{source: :settings_audit, error: inspect(reason)}]
      end

    setting_diagnostics ++ transaction_diagnostics
  end

  defp normalize_tui_profile(nil), do: "default"

  defp normalize_tui_profile(profile) when is_binary(profile) do
    case String.trim(profile) do
      "" -> "default"
      normalized -> normalized
    end
  end

  defp normalize_tui_profile(profile), do: profile

  defp tui_launch_result(disposition, written, present),
    do: tui_launch_result(disposition, written, present, [])

  defp tui_launch_result(disposition, written, present, diagnostics) do
    {:ok,
     %{
       disposition: disposition,
       written: written,
       present: present,
       diagnostics: diagnostics
     }}
  end

  defp put_user_settings_if_absent_snapshotted(values, context) do
    with {:ok, user_settings} <- read_user_settings(),
         {:ok, merged} <- merge_user_settings(user_settings) do
      {applied, preserved} = partition_absent_values(values, user_settings)

      case auto_enablement_disposition(values, user_settings) do
        :apply ->
          apply_absent_settings(user_settings, merged, applied, preserved, context)

        disposition ->
          {:ok, %{disposition: disposition, written: [], present: preserved}}
      end
    end
  end

  defp apply_absent_settings(user_settings, merged, applied, preserved, context) do
    updated_user_settings = put_dotted_values(user_settings, applied)
    updated_merged = put_dotted_values(merged, applied)

    with :ok <- Schema.validate_settings(updated_merged),
         {:ok, _settings} <- write_absent_subset(updated_user_settings, applied) do
      audit_absent_subset(applied, preserved, merged, context)
      refresh_resolved_pin()

      {:ok,
       %{
         disposition: :applied,
         written: applied |> Map.keys() |> Enum.sort(),
         present: preserved
       }}
    end
  end

  # The three values form one semantic enablement decision, even though raw
  # per-key stickiness is preserved. If consent became explicitly false or the
  # selected primary changed before this lock was acquired, applying the other
  # absent keys would bind enablement/disclosure to stale selection state.
  defp auto_enablement_disposition(values, user_settings) do
    requested_primary = Map.get(values, "model_preferences.primary")
    stored_primary = Schema.get_dotted(user_settings, "model_preferences.primary")
    stored_consent = Schema.get_dotted(user_settings, "intent.direct_answer_model_enabled")

    cond do
      stored_consent == false -> :explicitly_disabled
      stored_primary not in [nil, requested_primary] -> :selection_changed
      true -> :apply
    end
  end

  defp validate_auto_enablement_keys(values) do
    invalid_keys =
      values
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(@auto_enablement_keys, &1))
      |> Enum.sort()

    case invalid_keys do
      [] -> :ok
      keys -> {:error, {:settings_if_absent_keys_not_allowed, keys}}
    end
  end

  defp partition_absent_values(values, user_settings) do
    values
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({%{}, %{}}, fn {key, value}, {applied, preserved} ->
      case Schema.get_dotted(user_settings, key) do
        nil -> {Map.put(applied, key, value), preserved}
        stored -> {applied, Map.put(preserved, key, stored)}
      end
    end)
  end

  defp put_dotted_values(settings, values) do
    Enum.reduce(values, settings, fn {key, value}, acc -> Schema.put_dotted(acc, key, value) end)
  end

  defp write_absent_subset(_user_settings, applied) when map_size(applied) == 0, do: {:ok, :noop}
  defp write_absent_subset(user_settings, _applied), do: write_user_settings_locked(user_settings)

  defp audit_absent_subset(_applied, _preserved, _merged, %{audit?: false}), do: []
  defp audit_absent_subset(_applied, _preserved, _merged, %{"audit?" => false}), do: []

  defp audit_absent_subset(applied, preserved, merged, context) do
    per_key =
      applied
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} ->
        audit_write(key, Schema.get_dotted(merged, key), value, context)
      end)

    envelope =
      Audit.append_settings_transaction(Map.keys(applied) |> Enum.sort(), preserved, context)

    [per_key, envelope]
  end

  defp put_user_setting_snapshotted(key, value, context) do
    with {:ok, user_settings} <- read_user_settings(),
         {:ok, merged} <- merge_user_settings(user_settings),
         :ok <- Schema.validate_key_value(key, value, merged) do
      old_value = Schema.get_dotted(merged, key)
      updated_user_settings = Schema.put_dotted(user_settings, key, value)
      updated_merged = Schema.put_dotted(merged, key, value)

      with :ok <- Schema.validate_settings(updated_merged),
           {:ok, _settings} <- write_user_settings_locked(updated_user_settings) do
        diagnostics = audit_write(key, old_value, value, context)
        {:ok, updated_merged, updated_user_settings, diagnostics}
      end
    end
  end

  def merge_user_settings(user_settings) when is_map(user_settings) do
    user_settings = normalize_user_settings(user_settings)
    {:ok, deep_merge(Schema.defaults(), user_settings)}
  end

  def write_atomic(path, content) when is_binary(path) and is_binary(content) do
    path |> Path.dirname() |> File.mkdir_p!()
    tmp_path = "#{path}.tmp-#{System.pid()}-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} = error ->
        File.rm(tmp_path)
        {:error, {:settings_write_failed, reason(error, reason)}}
    end
  end

  def app_config do
    Application.get_env(@app, AllbertAssist.Settings, [])
  end

  defp write_user_settings_locked(settings) do
    Fragments.with_composition(fn -> validate_and_write(settings) end)
  end

  defp validate_and_write(settings) do
    with :ok <- VersionContract.reject_forward_versions(settings),
         {:ok, merged} <- merge_user_settings(settings),
         :ok <- Schema.validate_settings(merged),
         _root <- ensure_root!(),
         :ok <- write_atomic(settings_path(), YamlCodec.encode!(settings)) do
      refresh_resolved_pin()
      {:ok, settings}
    end
  end

  defp audit_write(_key, _old_value, _value, %{audit?: false}), do: []
  defp audit_write(_key, _old_value, _value, %{"audit?" => false}), do: []

  defp audit_write(key, old_value, value, context) do
    case Audit.append_setting(key, old_value, value, context) do
      {:ok, path} -> [%{source: :settings_audit, audit_path: path}]
      {:error, reason} -> [%{source: :settings_audit, error: inspect(reason)}]
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp reason(error, _reason), do: error

  defp normalize_user_settings(settings) when is_map(settings) do
    settings
    |> normalize_legacy_workspace_theme()
    |> normalize_dynamic_codegen_scope()
    |> normalize_model_preferences_aliases()
  end

  defp normalize_model_preferences_aliases(settings) do
    settings
    |> normalize_primary_model_preference()
    |> normalize_direct_answer_model_preference()
  end

  defp normalize_primary_model_preference(settings) do
    legacy = get_in(settings, ["intent", "model_profile"])
    primary = get_in(settings, ["model_preferences", "primary"])

    if is_binary(legacy) and legacy != "" and is_nil(primary) do
      Schema.put_dotted(settings, "model_preferences.primary", legacy)
    else
      settings
    end
  end

  defp normalize_direct_answer_model_preference(settings) do
    legacy = get_in(settings, ["intent", "direct_answer_model_profile"])
    direct_answer = get_in(settings, ["model_preferences", "tasks", "direct_answer"])

    if is_binary(legacy) and legacy != "" and is_nil(direct_answer) do
      Schema.put_dotted(settings, "model_preferences.tasks.direct_answer", [legacy])
    else
      settings
    end
  end

  defp normalize_legacy_workspace_theme(settings) do
    case get_in(settings, ["workspace", "theme"]) do
      value when is_binary(value) -> put_in(settings, ["workspace", "theme"], %{"mode" => value})
      _other -> settings
    end
  end

  defp normalize_dynamic_codegen_scope(settings) do
    settings
    |> normalize_dynamic_codegen_list("allowed_targets", ["action"])
    |> normalize_dynamic_codegen_list("allowed_action_permissions", [
      "read_only",
      "memory_write",
      "external_network"
    ])
    |> normalize_dynamic_codegen_list(
      "allowed_facades",
      ["append_memory", "external_network_request"],
      allow_empty?: true
    )
  end

  defp normalize_dynamic_codegen_list(settings, key, allowed, opts \\ []) do
    allow_empty? = Keyword.get(opts, :allow_empty?, false)

    case get_in(settings, ["dynamic_codegen", key]) do
      values when is_list(values) ->
        normalized =
          values
          |> Enum.map(&to_string/1)
          |> Enum.filter(&(&1 in allowed))
          |> case do
            [] when allow_empty? -> []
            [] -> [List.first(allowed)]
            values -> Enum.uniq(values)
          end

        put_in(settings, ["dynamic_codegen", key], normalized)

      _other ->
        settings
    end
  end
end
