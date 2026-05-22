defmodule AllbertAssist.SecurityEvalCase do
  @moduledoc """
  Shared helpers for v0.28 adversarial security evals.

  The harness is intentionally test-only. It drives real runtime boundaries
  when a fixture provides one, but also supports inert fixture results for
  harness self-tests and inventory validation.
  """

  use ExUnit.CaseTemplate

  alias AllbertAssist.Actions.Runner

  using opts do
    quote do
      use AllbertAssist.DataCase, async: unquote(Keyword.get(opts, :async, false))

      import AllbertAssist.SecurityEvalCase
    end
  end

  @type eval_result :: %{
          required(:decision) => atom(),
          required(:result) => term(),
          required(:trace) => map(),
          optional(:fixture) => map(),
          optional(:transport_calls) => map()
        }

  @spec run_eval(map()) :: eval_result()
  def run_eval(%{run: runner} = fixture) when is_function(runner, 1) do
    fixture
    |> runner.()
    |> normalize_eval(fixture)
  end

  def run_eval(%{eval_result: result} = fixture) when is_map(result) do
    normalize_eval(result, fixture)
  end

  def run_eval(%{boundary: {Runner, action}, input: input} = fixture) do
    params = Map.get(input, :params, %{})
    context = Map.get(input, :context, %{})

    action
    |> Runner.run(params, context)
    |> normalize_eval(fixture)
  end

  def run_eval(fixture) when is_map(fixture) do
    normalize_eval(
      %{
        decision: Map.get(fixture, :expected, :error),
        result: {:error, :no_eval_runner},
        trace: %{fixture_id: Map.get(fixture, :id), error: :no_eval_runner}
      },
      fixture
    )
  end

  @spec assert_allowed(eval_result()) :: eval_result()
  def assert_allowed(eval) do
    assert eval.decision == :allowed
    eval
  end

  @spec assert_denied(eval_result(), keyword()) :: eval_result()
  def assert_denied(eval, opts \\ []) do
    assert eval.decision == :denied

    if Keyword.get(opts, :no_side_effect?, false) do
      assert get_in(eval, [:trace, :side_effect_ran?]) in [false, nil]
    end

    eval
  end

  @spec assert_needs_confirmation(eval_result()) :: eval_result()
  def assert_needs_confirmation(eval) do
    assert eval.decision == :needs_confirmation
    eval
  end

  @spec assert_dropped(eval_result()) :: eval_result()
  def assert_dropped(eval) do
    assert eval.decision == :dropped
    eval
  end

  @spec assert_no_cross_user_leak(eval_result(), String.t()) :: eval_result()
  def assert_no_cross_user_leak(eval, other_user_id) do
    refute contains_value?(eval.result, other_user_id)
    refute contains_value?(eval.trace, other_user_id)
    eval
  end

  @spec assert_no_secret_in(eval_result(), [String.t()]) :: eval_result()
  def assert_no_secret_in(eval, secrets \\ ["sk-test-secret", "super-secret-token"]) do
    Enum.each(secrets, fn secret ->
      refute contains_value?(eval.result, secret)
      refute contains_value?(eval.trace, secret)
    end)

    eval
  end

  @spec assert_fixture_transport_calls(eval_result(), atom(), non_neg_integer()) :: eval_result()
  def assert_fixture_transport_calls(eval, boundary, expected_count) do
    assert get_in(eval, [:transport_calls, boundary]) == expected_count
    eval
  end

  @spec assert_trace_records(eval_result(), [atom()]) :: eval_result()
  def assert_trace_records(eval, keys) when is_list(keys) do
    Enum.each(keys, fn key ->
      assert Map.has_key?(eval.trace, key), "expected eval trace to include #{inspect(key)}"
    end)

    eval
  end

  defp normalize_eval({:ok, result}, fixture), do: normalize_eval(result, fixture)

  defp normalize_eval(result, fixture) when is_map(result) do
    trace =
      result
      |> Map.get(:trace, %{})
      |> Map.merge(trace_from_result(result))
      |> Map.put_new(:fixture_id, Map.get(fixture, :id))

    %{
      decision: decision_from(result, fixture),
      result: Map.get(result, :result, result),
      trace: trace,
      transport_calls: Map.get(result, :transport_calls, %{}),
      fixture: fixture
    }
  end

  defp normalize_eval(result, fixture) do
    %{
      decision: Map.get(fixture, :expected, :error),
      result: result,
      trace: %{fixture_id: Map.get(fixture, :id)},
      transport_calls: %{},
      fixture: fixture
    }
  end

  defp decision_from(result, fixture) do
    Map.get(result, :decision) ||
      Map.get(result, :status) ||
      Map.get(fixture, :expected) ||
      :error
  end

  defp trace_from_result(result) do
    runner_metadata = Map.get(result, :runner_metadata, %{})

    %{
      status: Map.get(result, :status),
      runner_action_id: Map.get(runner_metadata, :runner_action_id),
      permission_decision: Map.get(runner_metadata, :permission_decision)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp contains_value?(value, needle) when is_binary(value), do: String.contains?(value, needle)

  defp contains_value?(value, needle) when is_map(value) do
    Enum.any?(value, fn {key, val} ->
      contains_value?(key, needle) or contains_value?(val, needle)
    end)
  end

  defp contains_value?(value, needle) when is_list(value) do
    Enum.any?(value, &contains_value?(&1, needle))
  end

  defp contains_value?(value, needle) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> contains_value?(needle)
  end

  defp contains_value?(_value, _needle), do: false
end
