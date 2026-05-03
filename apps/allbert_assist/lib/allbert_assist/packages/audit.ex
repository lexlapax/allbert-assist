defmodule AllbertAssist.Packages.Audit do
  @moduledoc """
  Markdown audit records for v0.10 package-manager requests and runs.
  """

  alias AllbertAssist.Packages.InstallSpec
  alias AllbertAssist.Paths

  @type event :: :requested | :approved | :denied | :succeeded | :failed | :timed_out

  @spec root() :: String.t()
  def root, do: Paths.package_installs_root()

  @spec audit_root() :: String.t()
  def audit_root, do: Path.join(root(), "audit")

  @spec append(event(), InstallSpec.t(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  def append(event, %InstallSpec{} = spec, permission_decision, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    path = audit_path(now)

    File.mkdir_p!(Path.dirname(path))

    case File.write(path, render(event, spec, permission_decision, attrs, now), [:append]) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:package_install_audit_failed, reason}}
    end
  rescue
    exception ->
      {:error,
       {:package_install_audit_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  @spec audit_path(DateTime.t()) :: String.t()
  def audit_path(now \\ DateTime.utc_now()) do
    Path.join(audit_root(), "#{Calendar.strftime(now, "%Y-%m")}.md")
  end

  defp render(event, spec, permission_decision, attrs, now) do
    summary = InstallSpec.summary(spec)
    result = Map.get(attrs, :result, %{}) || %{}

    """

    ## #{DateTime.to_iso8601(now)} #{event}

    - event: #{event}
    - event_type: package_install
    - permission: package_install
    - decision: #{Map.get(permission_decision, :decision, "unknown")}
    - confirmation_id: #{Map.get(attrs, :confirmation_id, "none")}
    - manager: #{Map.get(summary, :manager)}
    - target_root: #{Map.get(summary, :resolved_target_root)}
    - packages: #{inspect(Map.get(summary, :packages, []))}
    - save_mode: #{Map.get(summary, :save_mode)}
    - executable: #{Map.get(summary, :executable)}
    - dry_run_argv: #{inspect(Map.get(summary, :dry_run_argv, []))}
    - execution_argv_preview: #{inspect(Map.get(summary, :execution_argv_preview, []))}
    - timeout_ms: #{Map.get(summary, :timeout_ms)}
    - max_output_bytes: #{Map.get(summary, :max_output_bytes)}
    - env_keys: #{inspect(Map.get(summary, :env_keys, []))}
    - denial_reason: #{inspect(Map.get(attrs, :denial_reason) || Map.get(summary, :denial_reason))}
    - result_status: #{Map.get(result, :status, "none")}
    - exit_status: #{Map.get(result, :exit_status, "none")}
    - timed_out: #{Map.get(result, :timed_out?, false)}
    - truncated: #{Map.get(result, :truncated?, false)}
    - output_bytes: #{Map.get(result, :output_bytes, 0)}
    - rollback_note: inspect package.json, package-lock.json, and node_modules changes before keeping the install
    - audit_version: 1
    """
  end
end
