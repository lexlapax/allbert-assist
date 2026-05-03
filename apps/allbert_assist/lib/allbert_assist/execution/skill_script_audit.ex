defmodule AllbertAssist.Execution.SkillScriptAudit do
  @moduledoc """
  Markdown audit records for v0.09 skill script execution.

  Audit records are bounded, redacted summaries. Script policy and execution
  remain owned by `run_skill_script`, Security Central, confirmations, and the
  runner.
  """

  alias AllbertAssist.Execution.SkillScriptSpec
  alias AllbertAssist.Paths

  @preview_limit 500
  @sensitive_value ~r/(sk-[A-Za-z0-9_-]+|api[_-]?key\s*[:=]\s*\S+|token\s*[:=]\s*\S+|password\s*[:=]\s*\S+|secret\s*[:=]\s*\S+)/i

  @type event ::
          :requested
          | :approved
          | :denied
          | :stale
          | :succeeded
          | :failed
          | :timed_out
          | :digest_mismatch

  @spec root() :: String.t()
  def root, do: Paths.execution_root()

  @spec audit_root() :: String.t()
  def audit_root, do: Path.join(root(), "audit")

  @spec append(event(), SkillScriptSpec.t(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  def append(event, %SkillScriptSpec{} = spec, permission_decision, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    path = audit_path(now)

    File.mkdir_p!(Path.dirname(path))

    case File.write(path, render(event, spec, permission_decision, attrs, now), [:append]) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:skill_script_audit_failed, reason}}
    end
  rescue
    exception ->
      {:error, {:skill_script_audit_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  @spec audit_path(DateTime.t()) :: String.t()
  def audit_path(now \\ DateTime.utc_now()) do
    Path.join(audit_root(), "#{Calendar.strftime(now, "%Y-%m")}.md")
  end

  defp render(event, spec, permission_decision, attrs, now) do
    summary = SkillScriptSpec.summary(spec)
    result = Map.get(attrs, :result, %{}) || %{}

    """

    ## #{DateTime.to_iso8601(now)} skill_script #{event}

    - event: #{event}
    - permission: skill_script_execute
    - decision: #{Map.get(permission_decision, :decision, "unknown")}
    - confirmation_id: #{Map.get(attrs, :confirmation_id, "none")}
    - skill: #{Map.get(summary, :skill_name)}
    - script_path: #{Map.get(summary, :script_path)}
    - script_sha256: #{Map.get(summary, :script_sha256)}
    - cwd: #{Map.get(summary, :resolved_cwd) || Map.get(summary, :cwd)}
    - sandbox_level: #{Map.get(summary, :sandbox_level)}
    - launch_mode: #{Map.get(summary, :launch_mode)}
    - args: #{inspect(redact_args(Map.get(summary, :args, [])))}
    - timeout_ms: #{Map.get(summary, :timeout_ms)}
    - max_output_bytes: #{Map.get(summary, :max_output_bytes)}
    - env_keys: #{inspect(Map.get(summary, :env_keys, []))}
    - denial_reason: #{inspect(Map.get(attrs, :denial_reason) || Map.get(summary, :denial_reason))}
    - exit_status: #{Map.get(result, :exit_status, "none")}
    - result_status: #{Map.get(result, :status, "none")}
    - timed_out: #{Map.get(result, :timed_out?, false)}
    - truncated: #{Map.get(result, :truncated?, false)}
    - output_bytes: #{Map.get(result, :output_bytes, 0)}
    - output_preview: #{inspect(redact_preview(Map.get(result, :stdout_preview, "")))}
    - audit_version: 1
    """
  end

  defp redact_args(args) when is_list(args), do: Enum.map(args, &redact_text/1)
  defp redact_args(_args), do: []

  defp redact_preview(value) when is_binary(value) do
    value
    |> binary_part(0, min(byte_size(value), @preview_limit))
    |> redact_text()
  end

  defp redact_preview(_value), do: ""

  defp redact_text(value) do
    value
    |> to_string()
    |> String.replace(@sensitive_value, "[REDACTED]")
  end
end
