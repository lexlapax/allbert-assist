defmodule AllbertAssist.PublicProtocol.RateLimiter do
  @moduledoc """
  Supervised token-bucket limiter for v0.51 HTTP public protocol ingress.

  M4 plugs this into HTTP controllers. M1 owns the shared substrate and tests
  that rate limiting can deny before runtime work.
  """

  use GenServer

  require Logger

  @fallback_event [:allbert, :public_protocol, :rate_limiter, :fallback]

  @type rate_limit :: %{
          optional(String.t()) => integer(),
          optional(atom()) => integer()
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Check one request for a `{surface, client_id}` bucket."
  @spec check(term(), term(), rate_limit(), keyword()) :: :ok | {:error, :rate_limited}
  def check(surface, client_id, rate_limit, opts \\ [])

  def check(surface, client_id, rate_limit, opts)
      when is_binary(client_id) or is_atom(client_id) do
    with {:ok, config} <- normalize_rate_limit(rate_limit) do
      now = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))
      key = {to_string(surface), to_string(client_id)}
      name = Keyword.get(opts, :name, __MODULE__)
      timeout = Keyword.get(opts, :timeout, 5_000)

      call({:check, key, config, now}, {:error, :rate_limited},
        name: name,
        timeout: timeout,
        fallback_context: {surface, client_id}
      )
    else
      {:error, _reason} -> {:error, :rate_limited}
    end
  end

  def check(_surface, _client_id, _rate_limit, _opts), do: {:error, :rate_limited}

  @doc false
  @spec reset_for_test() :: :ok
  def reset_for_test(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    timeout = Keyword.get(opts, :timeout, 5_000)

    call(:reset_for_test, :ok, name: name, timeout: timeout)
  end

  @impl true
  def init(_opts), do: {:ok, %{buckets: %{}}}

  @impl true
  def handle_call({:check, key, config, now}, _from, state) do
    {reply, bucket} =
      state.buckets
      |> Map.get(key)
      |> consume(config, now)

    buckets =
      state.buckets
      |> prune(now)
      |> Map.put(key, bucket)

    {:reply, reply, %{state | buckets: buckets}}
  end

  def handle_call(:reset_for_test, _from, _state), do: {:reply, :ok, %{buckets: %{}}}

  defp consume(nil, config, now) do
    tokens = capacity(config) - 1
    {:ok, %{tokens: tokens, updated_at: now, config: config}}
  end

  defp consume(bucket, config, now) do
    tokens = refilled_tokens(bucket, config, now)

    if tokens >= 1 do
      {:ok, %{tokens: tokens - 1, updated_at: now, config: config}}
    else
      {{:error, :rate_limited}, %{tokens: tokens, updated_at: now, config: config}}
    end
  end

  defp refilled_tokens(bucket, config, now) do
    elapsed = max(now - bucket.updated_at, 0)
    refill = elapsed * config.limit / config.period_ms

    min(capacity(config), bucket.tokens + refill)
  end

  defp capacity(%{limit: limit, burst: burst}), do: max(limit + burst, 1)

  defp prune(buckets, now) do
    Map.filter(buckets, fn {_key, bucket} ->
      now - bucket.updated_at <= max(bucket.config.period_ms * 2, 1_000)
    end)
  end

  defp normalize_rate_limit(rate_limit) when is_map(rate_limit) do
    config = %{
      limit: int_field(rate_limit, :limit, 60),
      period_ms: int_field(rate_limit, :period_ms, 60_000),
      burst: int_field(rate_limit, :burst, 10)
    }

    if config.limit >= 1 and config.limit <= 10_000 and
         config.period_ms >= 100 and config.period_ms <= 86_400_000 and
         config.burst >= 0 and config.burst <= 10_000 do
      {:ok, config}
    else
      {:error, :invalid_rate_limit}
    end
  end

  defp normalize_rate_limit(_rate_limit), do: {:error, :invalid_rate_limit}

  defp int_field(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp call(message, fallback, opts) do
    name = Keyword.fetch!(opts, :name)
    timeout = Keyword.fetch!(opts, :timeout)

    case Process.whereis(name) do
      nil ->
        fallback(:unavailable, fallback, Keyword.get(opts, :fallback_context))

      pid ->
        GenServer.call(pid, message, timeout)
    end
  catch
    :exit, reason ->
      fallback(fallback_reason(reason), fallback, Keyword.get(opts, :fallback_context))
  end

  defp fallback(_reason, fallback, nil), do: fallback

  defp fallback(reason, fallback, {surface, client_id}) do
    surface = bounded(surface)
    client_id = bounded(client_id)

    Logger.warning(
      "public protocol rate limiter unavailable surface=#{inspect(surface)} " <>
        "client_id=#{inspect(client_id)} reason=#{inspect(reason)}"
    )

    :telemetry.execute(@fallback_event, %{count: 1}, %{
      surface: surface,
      client_id: client_id,
      reason: reason
    })

    fallback
  end

  defp fallback_reason({:timeout, _call}), do: :timeout
  defp fallback_reason(:timeout), do: :timeout
  defp fallback_reason(_reason), do: :exit

  defp bounded(value) do
    value
    |> to_string()
    |> String.slice(0, 160)
  end
end
