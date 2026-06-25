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
      application_setting_issue(line, line_no, lines_by_no, issue_meta, params),
      web_direct_settings_read_issue(line, line_no, source_file, issue_meta),
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

  defp application_setting_issue(line, line_no, lines_by_no, issue_meta, params) do
    if String.contains?(line, "Application.get_env") do
      window = line_window(lines_by_no, line_no)

      setting_key =
        params
        |> Params.get(:operator_setting_keys, __MODULE__)
        |> Enum.find(&String.contains?(window, inspect(&1)))

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
    if web_surface_source_file?(source_file.filename) and direct_settings_get?(line) do
      issue_for(
        issue_meta,
        line,
        line_no,
        "Settings.get",
        "Read web settings through a registered read action or resolved settings snapshot."
      )
    end
  end

  defp web_surface_source_file?(filename),
    do: String.starts_with?(filename, "apps/allbert_assist_web/lib/")

  defp direct_settings_get?(line) do
    String.contains?(line, "Settings.get(") or
      String.contains?(line, "AllbertAssist.Settings.get(")
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
