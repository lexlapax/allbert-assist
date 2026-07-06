defmodule AllbertAssist.Credo.Check.SettingsCentralNoBypass do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      allowed_path_patterns: [
        ~r"(^|/)test/",
        ~r"^config/",
        ~r"^priv/credo_checks/"
      ],
      operator_env_vars: [
        "ALLBERT_TRACE_ENABLED",
        "ALLBERT_BROWSER_HOST_RESOLVER_RULES"
      ],
      allowed_infra_env_vars: [
        "ALLBERT_HOME",
        "ALLBERT_HOME_DIR",
        "ALLBERT_SETTINGS_ROOT",
        "ALLBERT_MEMORY_ROOT",
        "ALLBERT_ARTIFACTS_ROOT",
        "ALLBERT_TEST_KEEP_TMP",
        "ALLBERT_TUI_LOG_LEVEL",
        "ALLBERT_WEBHOOK_BASE_URL",
        "ALLBERT_SETTINGS_MASTER_KEY",
        "ALLBERT_TEMPLATE_SMOKE",
        # v0.62 packaging/daemon/vault infrastructure env (not operator-tunable
        # Settings Central keys): OTP release layout, plugin root, daemon
        # writer-lock flag, OS session/user for service management, the Ollama
        # endpoint probe, and the ratified vault-tier override (S5).
        "RELEASE_NAME",
        "RELEASE_ROOT",
        "ALLBERT_PLUGINS_ROOT",
        "ALLBERT_HOLD_WRITER_LOCK",
        "ALLBERT_VAULT_BACKEND",
        "ALLBERT_BINARY",
        "DBUS_SESSION_BUS_ADDRESS",
        "XDG_RUNTIME_DIR",
        "UID",
        "OLLAMA_HOST",
        "PORT"
      ],
      operator_setting_keys: [
        "runtime.trace_default",
        "runtime.trace_recent_entries_limit",
        "intent.router_decisive_confidence",
        "active_memory.internal_candidate_limit",
        "active_memory.excluded_sample_limit",
        "artifacts.ingestion_timeout_ms",
        "browser.driver.host_resolver_rules"
      ]
    ],
    explanations: [
      check: """
      Operator-tunable settings must be read through Settings Central.

      Direct `System.get_env/1` or `Application.get_env/2` reads for operator
      settings bypass schema validation, safe-write policy, auditing, and
      Settings Central provenance.
      """
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @impl true
  def run(%SourceFile{} = source_file, params) do
    if allowed_path?(source_file.filename, params) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      lines = SourceFile.lines(source_file)
      lines_by_no = Map.new(lines)

      lines
      |> Enum.flat_map(&issues_for_line(&1, source_file, lines_by_no, issue_meta, params))
      |> Enum.reverse()
    end
  end

  defp allowed_path?(filename, params) do
    params
    |> Params.get(:allowed_path_patterns, __MODULE__)
    |> Enum.any?(&path_matches?(filename, &1))
  end

  defp path_matches?(filename, %Regex{} = pattern), do: filename =~ pattern

  defp path_matches?(filename, pattern) when is_binary(pattern),
    do: String.contains?(filename, pattern)

  defp issues_for_line({line_no, line}, source_file, lines_by_no, issue_meta, params) do
    [
      env_issue(line, line_no, issue_meta, params),
      unknown_env_issue(line, line_no, issue_meta, params),
      application_setting_issue(line, line_no, lines_by_no, issue_meta, params),
      web_direct_settings_read_issue(line, line_no, source_file, issue_meta),
      web_infra_config_issue(line, line_no, source_file, issue_meta),
      legacy_trace_enabled_issue(line, line_no, source_file, lines_by_no, issue_meta)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp env_issue(line, line_no, issue_meta, params) do
    env_var =
      params
      |> Params.get(:operator_env_vars, __MODULE__)
      |> Enum.find(fn env_var ->
        String.contains?(line, "System.get_env") and String.contains?(line, inspect(env_var))
      end)

    if env_var do
      issue_for(
        issue_meta,
        line,
        line_no,
        inspect(env_var),
        "Read #{env_var} through Settings Central instead of System.get_env/1."
      )
    end
  end

  defp unknown_env_issue(line, line_no, issue_meta, params) do
    with env_var when is_binary(env_var) <- env_var_literal(line),
         false <- listed_env_var?(env_var, :operator_env_vars, params),
         false <- listed_env_var?(env_var, :allowed_infra_env_vars, params) do
      issue_for(
        issue_meta,
        line,
        line_no,
        inspect(env_var),
        "Classify #{env_var} as a Settings Central key or explicit infrastructure env before reading it with System.get_env/1."
      )
    else
      _other -> nil
    end
  end

  defp application_setting_issue(line, line_no, lines_by_no, issue_meta, params) do
    if String.contains?(line, "Application.get_env") do
      window = line_window(lines_by_no, line_no)
      setting_keys = Params.get(params, :operator_setting_keys, __MODULE__)

      setting_key =
        Enum.find(setting_keys, &String.contains?(window, inspect(&1))) ||
          dotted_setting_key(window) ||
          single_segment_setting_key(line, setting_keys)

      if setting_key do
        issue_for(
          issue_meta,
          line,
          line_no,
          "Application.get_env",
          "Read #{setting_key} through Settings.get/1 instead of Application.get_env."
        )
      end
    end
  end

  defp legacy_trace_enabled_issue(line, line_no, source_file, lines_by_no, issue_meta) do
    if trace_source_file?(source_file.filename) and String.contains?(line, "Application.get_env") do
      window = line_window(lines_by_no, line_no)

      if String.contains?(window, ":enabled") or String.contains?(window, "enabled:") do
        issue_for(
          issue_meta,
          line,
          line_no,
          "Application.get_env",
          "Read runtime.trace_default through Settings.get/1 instead of trace app env."
        )
      end
    end
  end

  defp web_direct_settings_read_issue(line, line_no, source_file, issue_meta) do
    if web_surface_source_file?(source_file.filename) and direct_web_settings_read?(line) do
      issue_for(
        issue_meta,
        line,
        line_no,
        direct_web_settings_trigger(line),
        "Read web settings through a registered read action or resolved settings snapshot."
      )
    end
  end

  defp web_infra_config_issue(line, line_no, source_file, issue_meta) do
    if web_surface_source_file?(source_file.filename) and direct_runtime_config_read?(line) do
      issue_for(
        issue_meta,
        line,
        line_no,
        direct_runtime_config_trigger(line),
        "Web surfaces must not read env/app config directly; route through Settings Central actions."
      )
    end
  end

  defp web_surface_source_file?(filename),
    do: String.starts_with?(filename, "apps/allbert_assist_web/lib/")

  defp direct_web_settings_read?(line) do
    String.contains?(line, "Settings.get(") or
      String.contains?(line, "AllbertAssist.Settings.get(") or
      String.contains?(line, "Settings.Store") or
      String.contains?(line, "AllbertAssist.Settings.Store") or
      String.contains?(line, "Store.resolved_settings(")
  end

  defp direct_web_settings_trigger(line) do
    cond do
      String.contains?(line, "Settings.Store") -> "Settings.Store"
      String.contains?(line, "AllbertAssist.Settings.Store") -> "AllbertAssist.Settings.Store"
      String.contains?(line, "Store.resolved_settings(") -> "Store.resolved_settings"
      true -> "Settings.get"
    end
  end

  defp direct_runtime_config_read?(line) do
    String.contains?(line, "System.get_env") or String.contains?(line, "Application.get_env")
  end

  defp direct_runtime_config_trigger(line) do
    if String.contains?(line, "System.get_env"), do: "System.get_env", else: "Application.get_env"
  end

  defp env_var_literal(line) do
    if String.contains?(line, "System.get_env") do
      case Regex.run(~r/System\.get_env\(\s*"([A-Z][A-Z0-9_]*)"/, line) do
        [_match, env_var] -> env_var
        _other -> nil
      end
    end
  end

  defp listed_env_var?(env_var, param_name, params) do
    params
    |> Params.get(param_name, __MODULE__)
    |> Enum.member?(env_var)
  end

  defp dotted_setting_key(window) do
    case Regex.run(~r/"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"/, window) do
      [_match, key] -> key
      _other -> nil
    end
  end

  # Catch a single-segment operator key (no dot) that matches a known Settings
  # Central namespace root, e.g. `Application.get_env(:app, "runtime")`. Matched
  # on the trigger line only so unrelated config windows are not flagged.
  defp single_segment_setting_key(line, setting_keys) do
    setting_keys
    |> Enum.map(&(&1 |> String.split(".") |> hd()))
    |> Enum.uniq()
    |> Enum.find(&String.contains?(line, inspect(&1)))
  end

  defp trace_source_file?(filename),
    do: String.ends_with?(filename, "apps/allbert_assist/lib/allbert_assist/trace.ex")

  defp line_window(lines_by_no, line_no) do
    line_no..(line_no + 4)
    |> Enum.map_join("\n", &Map.get(lines_by_no, &1, ""))
  end

  defp issue_for(issue_meta, line, line_no, trigger, message) do
    format_issue(
      issue_meta,
      message: message,
      trigger: trigger,
      line_no: line_no,
      column: column(line, trigger)
    )
  end

  defp column(line, trigger) do
    case :binary.match(line, trigger) do
      {index, _length} -> index + 1
      :nomatch -> 1
    end
  end
end
