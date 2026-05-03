defmodule AllbertAssist.External.Audit do
  @moduledoc """
  Markdown audit records for confirmed external HTTP/service requests.
  """

  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Paths

  @type event :: :requested | :approved | :denied | :succeeded | :failed

  @spec root() :: String.t()
  def root, do: Paths.external_root()

  @spec audit_root() :: String.t()
  def audit_root, do: Path.join(root(), "audit")

  @spec append(event(), RequestSpec.t(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  def append(event, %RequestSpec{} = spec, permission_decision, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    path = audit_path(now)

    File.mkdir_p!(Path.dirname(path))

    case File.write(path, render(event, spec, permission_decision, attrs, now), [:append]) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:external_audit_failed, reason}}
    end
  rescue
    exception ->
      {:error, {:external_audit_failed, {exception.__struct__, Exception.message(exception)}}}
  end

  @spec audit_path(DateTime.t()) :: String.t()
  def audit_path(now \\ DateTime.utc_now()) do
    Path.join(audit_root(), "#{Calendar.strftime(now, "%Y-%m")}.md")
  end

  defp render(event, spec, permission_decision, attrs, now) do
    summary = RequestSpec.summary(spec)
    result = Map.get(attrs, :result, %{}) || %{}

    """

    ## #{DateTime.to_iso8601(now)} #{event}

    - event: #{event}
    - permission: external_network
    - decision: #{Map.get(permission_decision, :decision, "unknown")}
    - confirmation_id: #{Map.get(attrs, :confirmation_id, "none")}
    - grant_ids: #{inspect(Map.get(attrs, :grant_ids, []))}
    - profile: #{Map.get(summary, :profile)}
    - method: #{Map.get(summary, :method)}
    - url: #{Map.get(summary, :url)}
    - host: #{Map.get(summary, :host)}
    - path: #{Map.get(summary, :path)}
    - timeout_ms: #{Map.get(summary, :timeout_ms)}
    - max_response_bytes: #{Map.get(summary, :max_response_bytes)}
    - retry_policy: #{Map.get(summary, :retry_policy)}
    - allow_redirects: #{Map.get(summary, :allow_redirects?)}
    - request_digest: #{Map.get(summary, :request_digest)}
    - denial_reason: #{inspect(Map.get(attrs, :denial_reason) || Map.get(summary, :denial_reason))}
    - target_status: #{Map.get(result, :status, "none")}
    - http_status: #{Map.get(result, :http_status, "none")}
    - duration_ms: #{Map.get(result, :duration_ms, "none")}
    - response_body_bytes: #{Map.get(result, :response_body_bytes, 0)}
    - truncated: #{Map.get(result, :truncated?, false)}
    - audit_version: 1
    """
  end
end
