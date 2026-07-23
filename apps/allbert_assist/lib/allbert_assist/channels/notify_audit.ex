defmodule AllbertAssist.Channels.NotifyAudit do
  @moduledoc false

  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Redactor

  def append(event, attrs) when is_atom(event) and is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    path = audit_path(now)
    File.mkdir_p!(Path.dirname(path))

    safe =
      attrs
      |> Map.take([
        :delivery_key,
        :fanout_id,
        :child_objective_id,
        :channel,
        :kind,
        :state,
        :reason,
        :attempt_count
      ])
      |> Redactor.redact()

    body = """

    ## #{DateTime.to_iso8601(now)} #{event}

    - authority: channel_autonomous_notify
    - delivery_key: #{Map.get(safe, :delivery_key, "none")}
    - fanout_id: #{Map.get(safe, :fanout_id, "none")}
    - child_objective_id: #{Map.get(safe, :child_objective_id, "none")}
    - channel: #{Map.get(safe, :channel, "unknown")}
    - kind: #{Map.get(safe, :kind, "unknown")}
    - state: #{Map.get(safe, :state, "unknown")}
    - reason: #{inspect(Map.get(safe, :reason))}
    - attempt_count: #{Map.get(safe, :attempt_count, 0)}
    - audit_version: 1
    """

    case File.write(path, body, [:append]) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:channel_notify_audit_failed, reason}}
    end
  rescue
    exception ->
      {:error,
       {:channel_notify_audit_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  def audit_root, do: Paths.channel_notify_audit_root()

  def audit_path(now \\ DateTime.utc_now()) do
    Path.join(audit_root(), "#{Calendar.strftime(now, "%Y-%m")}.md")
  end
end
