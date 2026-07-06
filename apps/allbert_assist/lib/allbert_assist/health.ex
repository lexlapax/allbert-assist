defmodule AllbertAssist.Health do
  @moduledoc """
  Bounded runtime health snapshot (v0.62 M5) — the read behind `allbert admin
  status` health and the web `/health` route. Read-only: it inspects supervised
  process state and a trivial DB round-trip; it starts nothing and grants no
  authority. Returns `:ok | :degraded` overall plus per-component detail.
  """

  @doc "A bounded health snapshot: %{status:, runtime:, database:, channels:}."
  def snapshot do
    runtime = runtime_status()
    database = database_status()
    channels = channels_status()

    overall =
      if runtime == :up and database == :ok and channels.status in [:up, :none],
        do: :ok,
        else: :degraded

    %{
      status: overall,
      runtime: runtime,
      database: database,
      channels: channels
    }
  end

  @doc "True when the overall snapshot is healthy."
  @spec healthy?() :: boolean()
  def healthy?, do: snapshot().status == :ok

  defp runtime_status do
    case Process.whereis(AllbertAssist.Repo) do
      pid when is_pid(pid) -> :up
      _nil -> :down
    end
  end

  defp database_status do
    case AllbertAssist.Repo.query("SELECT 1") do
      {:ok, _result} -> :ok
      _error -> :error
    end
  rescue
    _error -> :error
  end

  defp channels_status do
    case Process.whereis(AllbertAssist.Channels.Supervisor) do
      pid when is_pid(pid) ->
        count = pid |> Supervisor.which_children() |> length()
        %{status: if(count > 0, do: :up, else: :none), supervised: count}

      _nil ->
        %{status: :down, supervised: 0}
    end
  rescue
    _error -> %{status: :down, supervised: 0}
  end
end
