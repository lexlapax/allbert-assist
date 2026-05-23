defmodule AllbertAssist.Execution.Audit do
  @moduledoc """
  Markdown audit records for v0.08 local shell execution.

  Audit records are bounded, redacted summaries. They do not own policy or
  execution semantics; registered actions call this module after decisions.

  v0.31 keeps this module as the shell-command audit writer. New
  runtime-facing code should call `AllbertAssist.Runtime.Audit`.
  """

  alias AllbertAssist.Execution.CommandSpec
  alias AllbertAssist.Paths

  @preview_limit 500
  @sensitive_value ~r/(sk-[A-Za-z0-9_-]+|api[_-]?key\s*[:=]\s*\S+|token\s*[:=]\s*\S+|password\s*[:=]\s*\S+|secret\s*[:=]\s*\S+)/i

  @type event :: :requested | :approved | :denied | :succeeded | :failed | :timed_out

  @spec root() :: String.t()
  def root, do: Paths.execution_root()

  @spec audit_root() :: String.t()
  def audit_root, do: Path.join(root(), "audit")

  @spec append(event(), CommandSpec.t(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  def append(event, %CommandSpec{} = spec, permission_decision, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    path = audit_path(now)

    File.mkdir_p!(Path.dirname(path))

    case File.write(path, render(event, spec, permission_decision, attrs, now), [:append]) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:execution_audit_failed, reason}}
    end
  rescue
    exception ->
      {:error, {:execution_audit_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  @spec audit_path(DateTime.t()) :: String.t()
  def audit_path(now \\ DateTime.utc_now()) do
    Path.join(audit_root(), "#{Calendar.strftime(now, "%Y-%m")}.md")
  end

  defp render(event, spec, permission_decision, attrs, now) do
    summary = CommandSpec.summary(spec)
    result = Map.get(attrs, :result, %{}) || %{}

    """

    ## #{DateTime.to_iso8601(now)} #{event}

    - event: #{event}
    - permission: command_execute
    - decision: #{Map.get(permission_decision, :decision, "unknown")}
    - confirmation_id: #{Map.get(attrs, :confirmation_id, "none")}
    - executable: #{Map.get(summary, :executable)}
    - args: #{inspect(redact_args(Map.get(summary, :args, [])))}
    - cwd: #{Map.get(summary, :resolved_cwd) || Map.get(summary, :cwd)}
    - sandbox_level: #{Map.get(summary, :sandbox_level)}
    - command_class: #{Map.get(summary, :command_class)}
    - command_profile: #{Map.get(summary, :command_profile) || "none"}
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
