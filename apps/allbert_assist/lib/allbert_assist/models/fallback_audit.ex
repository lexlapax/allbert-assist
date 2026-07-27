defmodule AllbertAssist.Models.FallbackAudit do
  @moduledoc "Append-only, redacted audit rows for model fallback decisions."

  alias AllbertAssist.Settings.Store

  def audit_root, do: Path.join([Store.root(), "audit", "model_fallback"])

  def audit_path(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    Path.join(audit_root(), "#{Calendar.strftime(now, "%Y-%m")}.md")
  end

  def append(event, attrs, context \\ %{}) when is_atom(event) and is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    path = audit_path(now)
    File.mkdir_p!(Path.dirname(path))

    row = """

    ## #{DateTime.to_iso8601(now)} model_fallback.#{event}

    - actor: #{field(context, :actor, "local")}
    - channel: #{field(context, :channel, "unknown")}
    - failed_profile: #{Map.get(attrs, :failed_profile, "none")}
    - classification: #{Map.get(attrs, :classification, "unknown")}
    - answered_profile: #{Map.get(attrs, :answered_profile, "none")}
    - outcome: #{Map.get(attrs, :outcome, event)}
    - audit_version: 1
    """

    case File.write(path, row, [:append]) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:model_fallback_audit_failed, reason}}
    end
  rescue
    exception ->
      {:error,
       {:model_fallback_audit_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  defp field(map, key, default),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
end
