defmodule AllbertAssist.Settings.Store do
  @moduledoc false

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.Audit
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Settings.YamlCodec
  alias AllbertAssist.Settings.VersionContract

  @app :allbert_assist

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

  def write_user_settings(settings, opts \\ []) when is_map(settings) and is_list(opts) do
    settings = normalize_user_settings(settings)

    with :ok <- VersionContract.reject_forward_versions(settings),
         {:ok, merged} <- merge_user_settings(settings),
         :ok <- Schema.validate_settings(merged) do
      ensure_root!()
      write_atomic(settings_path(), YamlCodec.encode!(settings))
      {:ok, settings}
    end
  rescue
    exception ->
      {:error, {:settings_write_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  def resolved_settings do
    with {:ok, user_settings} <- read_user_settings(),
         :ok <- VersionContract.reject_forward_versions(user_settings),
         {:ok, merged} <- merge_user_settings(user_settings),
         :ok <- Schema.validate_settings(merged) do
      {:ok, merged, user_settings}
    end
  end

  def put_user_setting(key, value, context \\ %{}) do
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
