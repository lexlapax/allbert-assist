defmodule AllbertAssist.Health do
  @moduledoc """
  Bounded runtime health snapshot (v0.62 M5) — the read behind `allbert admin
  status` health and the web `/health` route. Read-only: it inspects supervised
  process state and a trivial DB round-trip; it starts nothing and grants no
  authority. Returns `:ok | :degraded` overall plus per-component detail.
  """

  alias AllbertAssist.Runtime.Attach.Server, as: AttachServer

  @doc "A bounded health snapshot for runtime, database, channels, and daemon attach."
  def snapshot do
    runtime = runtime_status()
    database = database_status()
    channels = channels_status()
    attach = attach_status()

    overall =
      if runtime == :up and database == :ok and channels.status in [:up, :none] and
           attach.status in [:up, :not_started],
         do: :ok,
         else: :degraded

    %{
      status: overall,
      runtime: runtime,
      database: database,
      channels: channels,
      attach: attach
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

  defp attach_status do
    case Process.whereis(AttachServer) do
      pid when is_pid(pid) -> AttachServer.status(pid)
      _nil -> %{status: :not_started}
    end
  rescue
    _error -> %{status: :down}
  catch
    :exit, _reason -> %{status: :down}
  end
end
