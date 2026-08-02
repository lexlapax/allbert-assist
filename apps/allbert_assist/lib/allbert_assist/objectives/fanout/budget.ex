defmodule AllbertAssist.Objectives.Fanout.Budget do
  @moduledoc """
  Resolves one immutable structural budget for a compiled fan-out plan.

  This is a value boundary, not a process or an authority boundary. The caller
  persists or passes the returned JSON-safe snapshot; later worker and composer
  stages consume it without re-resolving operator settings mid-plan.
  """

  alias AllbertAssist.Settings

  @legacy_version 1
  @version 2
  @manager_tokens_per_attempt 1_024
  @worker_calls_per_child 6
  @worker_tokens_per_child 3_072
  @composer_calls 6
  @composer_tokens 4_096
  @composer_max_output_tokens 1_024

  @legacy_worker_tokens_per_call 512
  @legacy_worker_calls_per_attempt 2
  @legacy_composer_calls 1
  @legacy_composer_tokens 1_024

  @setting_keys [
    "objectives.fanout.max_model_calls_per_plan",
    "objectives.fanout.max_output_tokens_per_plan",
    "objectives.fanout.max_elapsed_ms_per_plan",
    "objectives.fanout.max_worker_attempts_per_child"
  ]

  @snapshot_keys ~w[
    version child_count manager_attempts worker_attempts_per_child
    configured_model_calls required_model_calls configured_output_tokens
    required_output_tokens max_elapsed_ms
  ]

  @limit_setting_keys %{
    max_model_calls: "objectives.fanout.max_model_calls_per_plan",
    max_output_tokens: "objectives.fanout.max_output_tokens_per_plan",
    max_elapsed_ms: "objectives.fanout.max_elapsed_ms_per_plan",
    max_worker_attempts_per_child: "objectives.fanout.max_worker_attempts_per_child"
  }

  @typedoc "A bounded, JSON-safe plan budget frozen before fan-out starts."
  @type snapshot :: %{required(String.t()) => non_neg_integer()}

  @typedoc "Settings-owned plan limits frozen before the first manager call."
  @type limits :: %{
          required(:version) => 2,
          required(:max_model_calls) => pos_integer(),
          required(:max_output_tokens) => pos_integer(),
          required(:max_elapsed_ms) => pos_integer(),
          required(:max_worker_attempts_per_child) => pos_integer()
        }

  @type error_reason ::
          {:invalid_fanout_budget_input, String.t(), term()}
          | {:invalid_fanout_budget_limits, String.t(), term()}
          | {:fanout_budget_setting_unavailable, String.t(), term()}
          | {:fanout_budget_exhausted, map()}

  @doc "Resolve one Settings Central limits snapshot before manager work starts."
  @spec limits() :: {:ok, limits()} | {:error, error_reason()}
  def limits do
    Settings.with_resolved_settings(fn ->
      with {:ok, settings} <- fetch_settings() do
        {:ok,
         %{
           version: @version,
           max_model_calls: settings["objectives.fanout.max_model_calls_per_plan"],
           max_output_tokens: settings["objectives.fanout.max_output_tokens_per_plan"],
           max_elapsed_ms: settings["objectives.fanout.max_elapsed_ms_per_plan"],
           max_worker_attempts_per_child:
             settings["objectives.fanout.max_worker_attempts_per_child"]
         }}
      end
    end)
  end

  @doc "Resolve a structural plan budget from the current Settings Central limits."
  @spec resolve(integer(), integer()) :: {:ok, snapshot()} | {:error, error_reason()}
  def resolve(child_count, manager_attempts) do
    with :ok <- validate_count("child_count", child_count, 2, 16),
         :ok <- validate_count("manager_attempts", manager_attempts, 0, 2),
         {:ok, limits} <- limits() do
      build_snapshot(child_count, manager_attempts, limits)
    end
  end

  @doc "Resolve a structural plan budget from limits frozen before manager work began."
  @spec resolve(integer(), integer(), limits()) :: {:ok, snapshot()} | {:error, error_reason()}
  def resolve(child_count, manager_attempts, limits) do
    with :ok <- validate_count("child_count", child_count, 2, 16),
         :ok <- validate_count("manager_attempts", manager_attempts, 0, 2),
         :ok <- validate_limits(limits) do
      build_snapshot(child_count, manager_attempts, limits)
    end
  end

  @doc "Authorize one manager call against the limits frozen before its first call."
  @spec authorize_manager_attempt(limits(), integer()) :: :ok | {:error, error_reason()}
  def authorize_manager_attempt(limits, attempt) do
    with :ok <- validate_limits(limits),
         :ok <- validate_count("manager_attempt", attempt, 1, 2) do
      enforce_manager_limits(limits, attempt)
    end
  end

  @doc "Authorize one child run against its frozen retry and elapsed-time window."
  @spec authorize_worker(snapshot(), integer(), integer(), integer()) ::
          :ok
          | {:error,
             :invalid_fanout_budget_snapshot
             | :fanout_worker_attempt_budget_exhausted
             | :fanout_plan_deadline_exhausted}
  def authorize_worker(
        snapshot,
        attempt,
        deadline_unix_ms,
        now_unix_ms \\ System.system_time(:millisecond)
      )

  def authorize_worker(
        %{
          "version" => version,
          "worker_attempts_per_child" => max_attempts,
          "max_elapsed_ms" => max_elapsed_ms
        } = snapshot,
        attempt,
        deadline_unix_ms,
        now_unix_ms
      ) do
    if version in [@legacy_version, @version] and valid_snapshot?(snapshot) and
         valid_worker_window?(
           max_attempts,
           max_elapsed_ms,
           attempt,
           deadline_unix_ms,
           now_unix_ms
         ) do
      cond do
        attempt > max_attempts -> {:error, :fanout_worker_attempt_budget_exhausted}
        deadline_unix_ms <= now_unix_ms -> {:error, :fanout_plan_deadline_exhausted}
        true -> :ok
      end
    else
      {:error, :invalid_fanout_budget_snapshot}
    end
  end

  def authorize_worker(_snapshot, _attempt, _deadline_unix_ms, _now_unix_ms),
    do: {:error, :invalid_fanout_budget_snapshot}

  @doc "Authorize the bounded phase-separated composition protocol inside the frozen deadline."
  @spec authorize_composer(snapshot(), integer(), integer()) ::
          {:ok,
           %{
             required(:max_calls) => 6,
             required(:max_output_tokens) => 1_024,
             required(:timeout_ms) => pos_integer()
           }}
          | {:error,
             :invalid_fanout_budget_snapshot
             | :review_protocol_upgrade_required
             | :fanout_plan_deadline_exhausted}
  def authorize_composer(
        snapshot,
        deadline_unix_ms,
        now_unix_ms \\ System.system_time(:millisecond)
      )

  def authorize_composer(snapshot, deadline_unix_ms, now_unix_ms)
      when is_integer(deadline_unix_ms) and is_integer(now_unix_ms) do
    with :ok <- composer_compatibility(snapshot),
         remaining when remaining > 0 <- deadline_unix_ms - now_unix_ms do
      {:ok,
       %{
         max_calls: @composer_calls,
         max_output_tokens: @composer_max_output_tokens,
         timeout_ms: remaining
       }}
    else
      {:error, _reason} = error -> error
      _expired -> {:error, :fanout_plan_deadline_exhausted}
    end
  end

  def authorize_composer(_snapshot, _deadline_unix_ms, _now_unix_ms),
    do: {:error, :invalid_fanout_budget_snapshot}

  @doc "Classify one exact frozen budget for the phase-separated composer protocol."
  @spec composer_compatibility(snapshot()) ::
          :ok
          | {:error, :invalid_fanout_budget_snapshot | :review_protocol_upgrade_required}
  def composer_compatibility(snapshot) do
    case validate_snapshot(snapshot) do
      {:ok, %{"version" => @version}} -> :ok
      {:ok, %{"version" => @legacy_version}} -> {:error, :review_protocol_upgrade_required}
      {:error, :invalid_fanout_budget_snapshot} = error -> error
    end
  end

  @doc "Validate and return one exact closed durable budget snapshot."
  @spec validate_snapshot(map()) :: {:ok, snapshot()} | {:error, :invalid_fanout_budget_snapshot}
  def validate_snapshot(snapshot) when is_map(snapshot) do
    if valid_snapshot?(snapshot),
      do: {:ok, snapshot},
      else: {:error, :invalid_fanout_budget_snapshot}
  end

  def validate_snapshot(_snapshot), do: {:error, :invalid_fanout_budget_snapshot}

  defp build_snapshot(child_count, manager_attempts, limits) do
    worker_attempts = limits.max_worker_attempts_per_child

    required_calls =
      manager_attempts + child_count * @worker_calls_per_child + @composer_calls

    required_tokens =
      manager_attempts * @manager_tokens_per_attempt +
        child_count * @worker_tokens_per_child + @composer_tokens

    snapshot = %{
      "version" => limits.version,
      "child_count" => child_count,
      "manager_attempts" => manager_attempts,
      "worker_attempts_per_child" => worker_attempts,
      "configured_model_calls" => limits.max_model_calls,
      "required_model_calls" => required_calls,
      "configured_output_tokens" => limits.max_output_tokens,
      "required_output_tokens" => required_tokens,
      "max_elapsed_ms" => limits.max_elapsed_ms
    }

    enforce_structural_limits(snapshot)
  end

  defp validate_count(_field, value, minimum, maximum)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: :ok

  defp validate_count(field, value, _minimum, _maximum),
    do: {:error, {:invalid_fanout_budget_input, field, value}}

  defp validate_limits(%{
         version: @version,
         max_model_calls: model_calls,
         max_output_tokens: output_tokens,
         max_elapsed_ms: elapsed_ms,
         max_worker_attempts_per_child: worker_attempts
       }) do
    with :ok <- validate_limit(:max_model_calls, model_calls),
         :ok <- validate_limit(:max_output_tokens, output_tokens),
         :ok <- validate_limit(:max_elapsed_ms, elapsed_ms),
         :ok <- validate_limit(:max_worker_attempts_per_child, worker_attempts) do
      :ok
    end
  end

  defp validate_limits(limits),
    do: {:error, {:invalid_fanout_budget_limits, "snapshot", limits}}

  defp validate_limit(field, value) do
    key = Map.fetch!(@limit_setting_keys, field)

    case Settings.validate({key, value}) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:invalid_fanout_budget_limits, to_string(field), value}}
    end
  end

  defp enforce_structural_limits(snapshot) do
    cond do
      snapshot["required_model_calls"] > snapshot["configured_model_calls"] ->
        exhausted(
          "model_calls",
          snapshot["required_model_calls"],
          snapshot["configured_model_calls"]
        )

      snapshot["required_output_tokens"] > snapshot["configured_output_tokens"] ->
        exhausted(
          "output_tokens",
          snapshot["required_output_tokens"],
          snapshot["configured_output_tokens"]
        )

      true ->
        {:ok, snapshot}
    end
  end

  defp enforce_manager_limits(limits, attempt) do
    cond do
      attempt > limits.max_model_calls ->
        exhausted("model_calls", attempt, limits.max_model_calls)

      attempt * @manager_tokens_per_attempt > limits.max_output_tokens ->
        exhausted(
          "output_tokens",
          attempt * @manager_tokens_per_attempt,
          limits.max_output_tokens
        )

      true ->
        :ok
    end
  end

  defp valid_worker_window?(max_attempts, max_elapsed_ms, attempt, deadline_unix_ms, now_unix_ms) do
    Enum.all?([max_attempts, max_elapsed_ms, attempt], &(is_integer(&1) and &1 > 0)) and
      Enum.all?([deadline_unix_ms, now_unix_ms], &is_integer/1)
  end

  defp valid_snapshot?(
         %{
           "version" => version,
           "child_count" => child_count,
           "manager_attempts" => manager_attempts,
           "worker_attempts_per_child" => worker_attempts,
           "configured_model_calls" => configured_calls,
           "required_model_calls" => required_calls,
           "configured_output_tokens" => configured_tokens,
           "required_output_tokens" => required_tokens,
           "max_elapsed_ms" => max_elapsed_ms
         } = snapshot
       ) do
    with true <- version in [@legacy_version, @version],
         true <-
           Map.keys(snapshot) |> Enum.map(&to_string/1) |> Enum.sort() ==
             Enum.sort(@snapshot_keys),
         true <-
           valid_composer_dimensions?(
             child_count,
             manager_attempts,
             worker_attempts,
             max_elapsed_ms
           ),
         true <-
           valid_configured_limits?(
             configured_calls,
             configured_tokens,
             max_elapsed_ms,
             worker_attempts
           ),
         true <- Enum.all?([required_calls, required_tokens], &(is_integer(&1) and &1 > 0)) do
      {expected_calls, expected_tokens} =
        expected_totals(version, child_count, manager_attempts, worker_attempts)

      valid_composer_totals?(
        configured_calls,
        required_calls,
        expected_calls,
        configured_tokens,
        required_tokens,
        expected_tokens
      )
    else
      false -> false
    end
  end

  defp valid_snapshot?(_snapshot), do: false

  defp expected_totals(@version, child_count, manager_attempts, _worker_attempts) do
    {
      manager_attempts + child_count * @worker_calls_per_child + @composer_calls,
      manager_attempts * @manager_tokens_per_attempt +
        child_count * @worker_tokens_per_child + @composer_tokens
    }
  end

  defp expected_totals(@legacy_version, child_count, manager_attempts, worker_attempts) do
    {
      manager_attempts +
        child_count * worker_attempts * @legacy_worker_calls_per_attempt +
        @legacy_composer_calls,
      manager_attempts * @manager_tokens_per_attempt +
        child_count * worker_attempts * @legacy_worker_calls_per_attempt *
          @legacy_worker_tokens_per_call + @legacy_composer_tokens
    }
  end

  defp valid_composer_dimensions?(
         child_count,
         manager_attempts,
         worker_attempts,
         max_elapsed_ms
       ) do
    Enum.all?([
      integer_in_range?(child_count, 2, 16),
      integer_in_range?(manager_attempts, 0, 2),
      integer_in_range?(worker_attempts, 1, 4),
      is_integer(max_elapsed_ms) and max_elapsed_ms >= 1_000
    ])
  end

  defp valid_composer_totals?(
         configured_calls,
         required_calls,
         expected_calls,
         configured_tokens,
         required_tokens,
         expected_tokens
       ) do
    required_calls == expected_calls and configured_calls >= required_calls and
      required_tokens == expected_tokens and configured_tokens >= required_tokens
  end

  defp valid_configured_limits?(calls, tokens, elapsed_ms, worker_attempts) do
    Settings.validate({@limit_setting_keys.max_model_calls, calls}) == :ok and
      Settings.validate({@limit_setting_keys.max_output_tokens, tokens}) == :ok and
      Settings.validate({@limit_setting_keys.max_elapsed_ms, elapsed_ms}) == :ok and
      Settings.validate({@limit_setting_keys.max_worker_attempts_per_child, worker_attempts}) ==
        :ok
  end

  defp integer_in_range?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp exhausted(budget, required, configured) do
    {:error,
     {:fanout_budget_exhausted,
      %{"budget" => budget, "configured" => configured, "required" => required}}}
  end

  defp fetch_settings do
    Enum.reduce_while(@setting_keys, {:ok, %{}}, fn key, {:ok, values} ->
      case Settings.get(key) do
        {:ok, value} -> {:cont, {:ok, Map.put(values, key, value)}}
        {:error, reason} -> {:halt, {:error, {:fanout_budget_setting_unavailable, key, reason}}}
      end
    end)
  end
end
