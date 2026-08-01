defmodule AllbertAssist.Objectives.Fanout.Budget do
  @moduledoc """
  Resolves one immutable structural budget for a compiled fan-out plan.

  This is a value boundary, not a process or an authority boundary. The caller
  persists or passes the returned JSON-safe snapshot; later worker and composer
  stages consume it without re-resolving operator settings mid-plan.
  """

  alias AllbertAssist.Settings

  @version 1
  @manager_tokens_per_attempt 1_024
  @worker_tokens_per_call 512
  @worker_calls_per_attempt 2
  @composer_calls 1
  @composer_tokens 1_024

  @setting_keys [
    "objectives.fanout.max_model_calls_per_plan",
    "objectives.fanout.max_output_tokens_per_plan",
    "objectives.fanout.max_elapsed_ms_per_plan",
    "objectives.fanout.max_worker_attempts_per_child"
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
          required(:version) => 1,
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
          "version" => @version,
          "worker_attempts_per_child" => max_attempts,
          "max_elapsed_ms" => max_elapsed_ms
        },
        attempt,
        deadline_unix_ms,
        now_unix_ms
      ) do
    if valid_worker_window?(max_attempts, max_elapsed_ms, attempt, deadline_unix_ms, now_unix_ms) do
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

  defp build_snapshot(child_count, manager_attempts, limits) do
    worker_attempts = limits.max_worker_attempts_per_child

    required_calls =
      manager_attempts +
        child_count * worker_attempts * @worker_calls_per_attempt + @composer_calls

    required_tokens =
      manager_attempts * @manager_tokens_per_attempt +
        child_count * worker_attempts * @worker_calls_per_attempt * @worker_tokens_per_call +
        @composer_tokens

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
