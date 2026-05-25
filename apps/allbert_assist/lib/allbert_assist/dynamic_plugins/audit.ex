defmodule AllbertAssist.DynamicPlugins.Audit do
  @moduledoc """
  Durable, redacted lifecycle audit records for v0.37 dynamic plugin drafts.

  Dynamic draft metadata and sandbox reports remain the detailed evidence
  artifacts. This audit is the operator timeline for request, evidence,
  integration, rollback, disablement, and reconcile decisions.
  """

  require Logger

  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Signals

  @preview_limit 2_000

  @type event ::
          :draft_requested
          | :sandbox_report_recorded
          | :tier_transition
          | :discarded
          | :integration_attempted
          | :trusted_validation_passed
          | :compiled
          | :registered
          | :integrated
          | :integration_denied
          | :rollback_requested
          | :rolled_back
          | :rollback_denied
          | :live_loader_disabled
          | :reconcile_completed
          | :reconcile_denied

  @spec audit_root() :: String.t()
  def audit_root, do: Paths.dynamic_plugins_audit_root()

  @spec audit_path(DateTime.t()) :: String.t()
  def audit_path(now \\ DateTime.utc_now()) do
    Path.join(audit_root(), "#{Calendar.strftime(now, "%Y-%m")}.md")
  end

  @spec append(event(), map()) :: {:ok, String.t()} | {:error, term()}
  def append(event, metadata \\ %{}) when is_atom(event) and is_map(metadata) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    path = audit_path(now)
    metadata = metadata |> redact_paths() |> Redactor.redact(:audits)

    File.mkdir_p!(Path.dirname(path))

    case File.write(path, render(event, metadata, now), [:append]) do
      :ok ->
        emit_signal(event, metadata)
        {:ok, path}

      {:error, reason} ->
        {:error, {:dynamic_plugin_audit_failed, reason}}
    end
  rescue
    exception ->
      {:error,
       {:dynamic_plugin_audit_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  defp render(event, metadata, now) do
    """

    ## #{DateTime.to_iso8601(now)} #{event}

    - event: #{event}
    - operator_id: #{Map.get(metadata, :operator_id) || Map.get(metadata, "operator_id") || "unknown"}
    - slug: #{Map.get(metadata, :slug) || Map.get(metadata, "slug") || "unknown"}
    - revision: #{Map.get(metadata, :revision) || Map.get(metadata, "revision") || "unknown"}
    - metadata: #{preview(metadata)}
    - audit_version: 1
    """
  end

  defp emit_signal(event, metadata) do
    case Signals.dynamic_codegen_lifecycle(event, metadata) do
      {:ok, signal} ->
        Signals.log(signal)

      {:error, reason} ->
        Logger.debug(
          "dynamic plugin lifecycle signal skipped event=#{event} reason=#{inspect(reason)}"
        )
    end
  end

  defp preview(value) do
    rendered = inspect(value, limit: 50, printable_limit: @preview_limit)
    binary_part(rendered, 0, min(byte_size(rendered), @preview_limit))
  end

  defp redact_paths(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {key, redact_paths(val)} end)
    |> Map.new()
  end

  defp redact_paths(value) when is_list(value), do: Enum.map(value, &redact_paths/1)

  defp redact_paths(value) when is_binary(value) do
    String.replace(value, Paths.home(), "<ALLBERT_HOME>")
  end

  defp redact_paths(value), do: value
end
