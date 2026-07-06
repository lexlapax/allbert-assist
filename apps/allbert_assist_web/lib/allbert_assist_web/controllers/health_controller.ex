defmodule AllbertAssistWeb.HealthController do
  @moduledoc """
  The `/health` endpoint (v0.62 M5) — a bounded JSON runtime health snapshot an
  operator or a service supervisor can poll. Read-only; grants no authority and
  exposes no secret. 200 when healthy, 503 when degraded.
  """
  use AllbertAssistWeb, :controller

  def show(conn, _params) do
    snapshot = AllbertAssist.Health.snapshot()
    code = if snapshot.status == :ok, do: 200, else: 503

    conn
    |> put_status(code)
    |> json(snapshot)
  end
end
