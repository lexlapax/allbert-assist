defmodule AllbertAssist.Memory.ProjectionSync do
  @moduledoc """
  The single seam that advances the Memory projection after a canonical claim
  transition.

  v1.3 M9.b.12.a. Every canonical claim writer must call this once its append
  has returned. Two shipped defects came from call sites that did not:

    * M9.b.10 — nothing bootstrapped the first generation on a fresh Home, so a
      kept claim could never be retrieved.
    * M9.b.11 — archive and restore advanced canonical state and left the
      projection at the revision from the original keep, so the canonical
      recheck refused to serve a claim the operator had just restored.

  Both are the same shape: canonical moves, the projection does not, and
  retrieval correctly refuses to serve a stale candidate. ADR 0089 makes that
  recheck the reason a stale projection can never become authoritative; it is
  not a substitute for advancing the projection.

  This deliberately runs **after** `Memory.Claims.append/3` returns rather than
  inside it. `append/3` wraps its write in `lock(claim_id, …)` and
  `Projection.refresh_claim/1` reads back through `Claims.read/1`, so
  propagating inside the writer would hold the per-claim lock across a
  `GenServer.call` to the projection owner and couple the canonical writer to
  it. Given v1.1's single-writer contention history that is the wrong trade.
  """

  alias AllbertAssist.Memory.Projection

  @type outcome :: %{required(:outcome) => String.t(), optional(atom()) => term()}

  @doc """
  Advance the projection for one claim, or queue the repair that will.

  Returns a content-free outcome map suitable for a durable result payload:
  `%{outcome: "refreshed", revision: n}` when the projection advanced, or
  `%{outcome: "repair_pending", reason: binary}` when it could not and a repair
  was queued instead. `repair_pending` names a repair that is actually
  scheduled; before M9.b.11.b it named one nobody had queued.
  """
  @spec refresh(String.t()) :: outcome()
  def refresh(claim_id) when is_binary(claim_id) do
    if Process.whereis(Projection) do
      case Projection.refresh_claim(claim_id) do
        {:ok, refreshed} ->
          %{outcome: "refreshed", revision: refreshed.projection_revision}

        {:error, reason} ->
          Projection.queue_repair([reason])
          %{outcome: "repair_pending", reason: inspect(reason)}
      end
    else
      %{outcome: "repair_pending", reason: "projection_owner_unavailable"}
    end
  end

  def refresh(_claim_id), do: %{outcome: "repair_pending", reason: "invalid_claim_id"}
end
