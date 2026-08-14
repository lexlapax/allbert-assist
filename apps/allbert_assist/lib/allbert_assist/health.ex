defmodule AllbertAssist.Health do
  @moduledoc """
  Bounded runtime health snapshot (v0.62 M5) — the read behind `allbert admin
  status` health and the web `/health` route. Read-only: it inspects supervised
  process state and a trivial DB round-trip; it starts nothing and grants no
  authority. Returns `:ok | :degraded` overall plus per-component detail.
  """

  alias AllbertAssist.Runtime.Attach.Server, as: AttachServer

  @readiness_timeout 100

  @doc "A bounded health snapshot for runtime, database, channels, and daemon attach."
  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ [])

  def snapshot(opts) when is_list(opts) do
    runtime = runtime_status()
    database = database_status()
    channels = channels_status()
    attach = attach_status()
    pack = pack_status(opts)

    overall =
      if runtime == :up and database == :ok and channels.status in [:up, :none] and
           attach.status in [:up, :not_started] and pack.status == :ready,
         do: :ok,
         else: :degraded

    %{
      status: overall,
      runtime: runtime,
      database: database,
      channels: channels,
      attach: attach,
      pack: pack
    }
  end

  def snapshot(_opts), do: snapshot([])

  @doc "True when the overall snapshot is healthy."
  @spec healthy?(keyword()) :: boolean()
  def healthy?(opts \\ []), do: snapshot(opts).status == :ok

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

  # Health is a residual diagnostic and must not depend upward on composition.
  # The coordinator identity is intentionally represented only by its stable
  # registered name/pid liveness; Pack Readiness remains the source of epoch
  # phase and required-owner acknowledgement evidence.
  defp pack_status(opts) do
    readiness = Keyword.get(opts, :readiness, AllbertAssist.Pack.Readiness)
    coordinator = Keyword.get(opts, :coordinator, :allbert_pack_composition_owner)

    readiness
    |> readiness_status()
    |> pack_status_from_readiness(coordinator)
  end

  defp pack_status_from_readiness(
         {:ok,
          %{
            phase: :ready,
            snapshot_digest: digest,
            expected_ids: expected_ids,
            acked_ids: acked_ids
          }},
         coordinator
       )
       when is_binary(digest) and is_list(expected_ids) and is_list(acked_ids) do
    %{
      status:
        if(expected_ids == acked_ids and coordinator_ready?(coordinator, digest),
          do: :ready,
          else: :unavailable
        ),
      phase: :ready,
      snapshot_digest: digest,
      expected_ids: expected_ids,
      acked_ids: acked_ids,
      coordinator: coordinator_status(coordinator, digest)
    }
  end

  defp pack_status_from_readiness(
         {:ok,
          %{
            phase: phase,
            snapshot_digest: digest,
            expected_ids: expected_ids,
            acked_ids: acked_ids
          }},
         coordinator
       )
       when phase in [:collecting, :authorizing, :ready] and is_list(expected_ids) and
              is_list(acked_ids) do
    %{
      status: :unavailable,
      phase: phase,
      snapshot_digest: if(is_binary(digest), do: digest, else: nil),
      expected_ids: expected_ids,
      acked_ids: acked_ids,
      coordinator: coordinator_status(coordinator, digest)
    }
  end

  defp pack_status_from_readiness(_other, coordinator) do
    %{
      status: :unavailable,
      phase: :unavailable,
      snapshot_digest: nil,
      expected_ids: [],
      acked_ids: [],
      coordinator: coordinator_status(coordinator, nil)
    }
  end

  defp readiness_status(readiness) do
    readiness.status(timeout: @readiness_timeout)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp coordinator_ready?(coordinator, digest) do
    coordinator_status(coordinator, digest) == :ready
  end

  # The coordinator lives in composition, so this stays a protocol-level
  # GenServer read rather than a residual-to-composition module dependency.
  defp coordinator_status(coordinator, digest) do
    case GenServer.call(coordinator, :status, @readiness_timeout) do
      %{phase: :ready, epoch: %{snapshot_digest: ^digest}} when is_binary(digest) -> :ready
      _other -> :unavailable
    end
  catch
    :exit, _reason -> :unavailable
  end
end
