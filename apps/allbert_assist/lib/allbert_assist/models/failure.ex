defmodule AllbertAssist.Models.Failure do
  @moduledoc """
  Typed provider-failure classification for bounded model failover.

  Adapters should return `normalized/2`. The defensive `classify/1` clauses
  exist for test adapters and legacy boundaries; unknown outcomes are partial
  because they may have produced output before failing.
  """

  @type classification :: :definitive | :ambiguous | :partial
  @type normalized :: {:provider_failure, classification(), term()}

  @spec normalized(classification(), term()) :: normalized()
  def normalized(classification, reason)
      when classification in [:definitive, :ambiguous, :partial],
      do: {:provider_failure, classification, reason}

  @spec classify(term()) :: classification()
  def classify({:provider_failure, classification, _reason})
      when classification in [:definitive, :ambiguous, :partial],
      do: classification

  def classify(reason)
      when reason in [:econnrefused, :connection_refused, :auth_rejected, :model_not_found],
      do: :definitive

  def classify({kind, _detail})
      when kind in [:econnrefused, :connection_refused, :auth_rejected, :model_not_found],
      do: :definitive

  def classify({:http_status, status}) when status in [401, 403, 404], do: :definitive

  def classify(%ReqLLM.Error.API.Request{status: status}) when status in [401, 403, 404],
    do: :definitive

  def classify(%ReqLLM.Error.API.Request{cause: cause}) when not is_nil(cause),
    do: classify(cause)

  def classify({:transport_error, reason, _url}), do: classify(reason)
  def classify(%Req.TransportError{reason: reason}), do: classify(reason)
  def classify(reason) when reason in [:timeout, :etimedout], do: :ambiguous
  def classify({kind, _detail}) when kind in [:timeout, :etimedout], do: :ambiguous
  def classify(%{partial?: true}), do: :partial
  def classify(_unknown), do: :partial
end
