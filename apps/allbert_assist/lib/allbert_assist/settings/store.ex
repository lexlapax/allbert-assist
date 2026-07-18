defmodule AllbertAssist.Settings.Store do
  @moduledoc false

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.Audit
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Settings.VersionContract
  alias AllbertAssist.Settings.YamlCodec

  @app :allbert_assist

  # v1.0.2 M8.4: process-scoped turn snapshot (see with_resolved_settings/1).
  @resolved_pin_key {__MODULE__, :pinned_resolved_settings}
  @resolution_hook_key {__MODULE__, :resolution_hook}

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

    Fragments.with_composition(fn ->
      with :ok <- VersionContract.reject_forward_versions(settings),
           {:ok, merged} <- merge_user_settings(settings),
           :ok <- Schema.validate_settings(merged) do
        ensure_root!()
        write_atomic(settings_path(), YamlCodec.encode!(settings))
        refresh_resolved_pin()
        {:ok, settings}
      end
    end)
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
    Fragments.with_composition(fn -> put_user_setting_snapshotted(key, value, context) end)
  end

  defp put_user_setting_snapshotted(key, value, context) do
    with {:ok, user_settings} <- read_user_settings(),
         {:ok, merged} <- merge_user_settings(user_settings),
         :ok <- Schema.validate_key_value(key, value, merged) do
      old_value = Schema.get_dotted(merged, key)
      updated_user_settings = Schema.put_dotted(user_settings, key, value)
      updated_merged = Schema.put_dotted(merged, key, value)

      with :ok <- Schema.validate_settings(updated_merged),
           {:ok, _settings} <- write_user_settings(updated_user_settings) do
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
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

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
