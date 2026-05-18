defmodule StockSage.Agents.NativeCoordinator.Commands.ParityRun do
  @moduledoc """
  Run native/Python parity for StockSage analysis requests.

  This command is explicit comparison infrastructure. It never runs Python as
  fallback for a failed native analysis; callers must request `engine: "both"`.
  """

  use Jido.Action,
    name: "stocksage_native_coordinator_parity_run",
    description: "Run native and Python StockSage engines and compute parity."

  alias AllbertAssist.Settings
  alias AllbertAssist.Signals, as: AllbertSignals
  alias Jido.Signal
  alias StockSage.Agents.NativeCoordinator.Commands.Analyze
  alias StockSage.TraderBridge

  @ratings ["Sell", "Underweight", "Hold", "Overweight", "Buy"]
  @default_timeout_ms 300_000

  @impl true
  def run(params, _context) do
    request = normalize_request(params)
    {native_result, python_result} = run_engines(request)
    diff = parity_diff(native_result, python_result, parity_variance())

    case {native_result, python_result} do
      {{:error, native_reason}, {:error, python_reason}} ->
        reason = {:parity_failed, %{native: native_reason, python: python_reason}}

        {:ok,
         %{
           active_runs: %{},
           last_command: :parity_run,
           last_result: {:error, reason},
           last_error: inspect(reason),
           last_summary: %{ticker: field(request, :ticker), engine: "both", status: :failed}
         }}

      _other ->
        report = merged_report(request, native_result, python_result, diff)
        emit_parity_completed(request, report)

        {:ok,
         %{
           active_runs: %{},
           last_command: :parity_run,
           last_result: {:ok, report},
           last_error: nil,
           last_summary: Map.take(report, [:ticker, :analysis_date, :engine, :status])
         }}
    end
  end

  @doc false
  def parity_diff(native_result, python_result, variance) do
    native_report = ok_report(native_result)
    python_report = ok_report(python_result)
    native_rating = rating(native_report)
    python_rating = rating(python_report)
    native_confidence = confidence(native_report)
    python_confidence = confidence(python_report)
    agreement = rating_agreement(native_rating, python_rating)
    confidence_delta = confidence_delta(native_confidence, python_confidence)
    within_variance = not is_nil(confidence_delta) and abs(confidence_delta) < variance

    %{
      "native_status" => result_status(native_result),
      "python_status" => result_status(python_result),
      "native_rating" => native_rating,
      "python_rating" => python_rating,
      "rating_agreement" => agreement,
      "native_confidence" => native_confidence,
      "python_confidence" => python_confidence,
      "confidence_delta" => confidence_delta,
      "within_variance" => within_variance,
      "parity_pass" =>
        result_status(native_result) == "ok" and result_status(python_result) == "ok" and
          agreement >= 0.5 and within_variance,
      "native_error" => error_reason(native_result),
      "python_error" => error_reason(python_result),
      "computed_at" => DateTime.utc_now()
    }
    |> drop_nil_values()
    |> json_safe()
  end

  @doc false
  def rating_agreement(native_rating, python_rating) do
    with {:ok, native_index} <- rating_index(native_rating),
         {:ok, python_index} <- rating_index(python_rating) do
      case abs(native_index - python_index) do
        0 -> 1.0
        1 -> 0.5
        _distance -> 0.0
      end
    else
      _other -> 0.0
    end
  end

  defp run_engines(request) do
    timeout = timeout_ms()

    native_task =
      Task.async(fn ->
        request
        |> Map.put(:engine, "native")
        |> Analyze.analyze()
      end)

    python_task =
      Task.async(fn ->
        request
        |> python_params()
        |> TraderBridge.analyze()
      end)

    {
      await_engine(native_task, timeout),
      await_engine(python_task, timeout)
    }
  end

  defp await_engine(task, timeout) do
    Task.await(task, timeout)
  catch
    :exit, {:timeout, _details} ->
      Task.shutdown(task, :brutal_kill)
      {:error, :timeout}

    :exit, reason ->
      {:error, {:task_exit, reason}}
  end

  defp merged_report(request, native_result, python_result, diff) do
    native_report = ok_report(native_result)
    python_report = ok_report(python_result)
    recommendation = field(native_report, :recommendation) || rating(python_report) || "Hold"

    warnings =
      []
      |> maybe_warning(:native, native_result)
      |> maybe_warning(:python, python_result)
      |> Enum.reverse()

    %{
      status: :ok,
      engine: "both",
      request_id: field(request, :request_id) || "parity-#{System.unique_integer([:positive])}",
      ticker: field(request, :ticker, "UNKNOWN"),
      analysis_date: field(request, :analysis_date),
      objective_id: field(request, :objective_id),
      step_id: field(request, :step_id),
      native_report: json_safe(native_report),
      python_report: json_safe(python_report),
      parity_diff: diff,
      final_trade_decision: recommendation,
      recommendation: recommendation,
      confidence: field(native_report, :confidence) || confidence(python_report) || 0.5,
      summary: summary(request, native_result, python_result, diff),
      stub: field(python_report, :stub, false),
      warnings: warnings,
      generated_at: DateTime.utc_now()
    }
    |> drop_nil_values()
  end

  defp summary(request, native_result, python_result, diff) do
    ticker = field(request, :ticker, "UNKNOWN")
    pass? = Map.get(diff, "parity_pass", false)

    cond do
      result_status(native_result) == "ok" and result_status(python_result) == "ok" ->
        "Native/Python parity run completed for #{ticker}; parity_pass=#{pass?}."

      result_status(native_result) == "ok" ->
        "Native analysis completed for #{ticker}; Python comparison failed."

      true ->
        "Python comparison completed for #{ticker}; native analysis failed."
    end
  end

  defp maybe_warning(warnings, _engine, {:ok, _report}), do: warnings

  defp maybe_warning(warnings, engine, {:error, reason}),
    do: ["#{engine}: #{inspect(reason)}" | warnings]

  defp python_params(request) do
    %{
      ticker: field(request, :ticker, "UNKNOWN"),
      analysis_date: field(request, :analysis_date),
      engine: "tradingagents",
      force_stub: field(request, :force_stub, false)
    }
    |> drop_nil_values()
  end

  defp normalize_request(params) do
    %{
      request_id: field(params, :request_id) || "parity-#{System.unique_integer([:positive])}",
      ticker: field(params, :ticker, "UNKNOWN"),
      analysis_date: field(params, :analysis_date),
      user_id: field(params, :user_id),
      operator_id: field(params, :operator_id) || field(params, :user_id),
      objective_id: field(params, :objective_id),
      step_id: field(params, :step_id),
      thread_id: field(params, :thread_id),
      session_id: field(params, :session_id),
      trace_id: field(params, :trace_id),
      evidence_mode: field(params, :evidence_mode),
      fixture: field(params, :fixture),
      force_stub: field(params, :force_stub),
      parent: field(params, :parent, %{}),
      max_debate_rounds: field(params, :max_debate_rounds),
      max_risk_rounds: field(params, :max_risk_rounds)
    }
    |> drop_nil_values()
  end

  defp ok_report({:ok, report}), do: report
  defp ok_report(_other), do: nil

  defp result_status({:ok, _report}), do: "ok"
  defp result_status({:error, _reason}), do: "error"

  defp error_reason({:error, reason}), do: inspect(reason, limit: 20, printable_limit: 500)
  defp error_reason(_other), do: nil

  defp rating(report) when is_map(report) do
    report
    |> field(:final_trade_decision)
    |> normalize_rating()
    |> case do
      nil ->
        report
        |> field(:recommendation)
        |> normalize_rating()

      rating ->
        rating
    end
    |> case do
      nil ->
        report
        |> field(:rating)
        |> normalize_rating()

      rating ->
        rating
    end
    |> case do
      nil ->
        report
        |> field(:decision)
        |> normalize_rating()

      rating ->
        rating
    end
  end

  defp rating(_report), do: nil

  defp normalize_rating(value) when is_binary(value) do
    Enum.find(@ratings, fn rating ->
      value
      |> String.downcase()
      |> String.contains?(String.downcase(rating))
    end)
  end

  defp normalize_rating(_value), do: nil

  defp confidence(report) when is_map(report) do
    report
    |> field(:confidence)
    |> normalize_confidence()
  end

  defp confidence(_report), do: nil

  defp normalize_confidence(value) when is_float(value), do: value
  defp normalize_confidence(value) when is_integer(value), do: value / 1

  defp normalize_confidence(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp normalize_confidence(_value), do: nil

  defp confidence_delta(native_confidence, python_confidence)
       when is_number(native_confidence) and is_number(python_confidence) do
    Float.round(native_confidence - python_confidence, 4)
  end

  defp confidence_delta(_native_confidence, _python_confidence), do: nil

  defp rating_index(rating) when is_binary(rating) do
    case Enum.find_index(@ratings, &(&1 == rating)) do
      nil -> {:error, :unknown_rating}
      index -> {:ok, index}
    end
  end

  defp rating_index(_rating), do: {:error, :unknown_rating}

  defp parity_variance do
    case Settings.get("stocksage.native_parity_variance") do
      {:ok, value} when is_float(value) -> value
      {:ok, value} when is_integer(value) -> value / 1
      _other -> 0.25
    end
  rescue
    _exception -> 0.25
  end

  defp timeout_ms do
    case Settings.get("stocksage.bridge_timeout_ms") do
      {:ok, value} when is_integer(value) and value > 0 -> value
      _other -> @default_timeout_ms
    end
  rescue
    _exception -> @default_timeout_ms
  end

  defp emit_parity_completed(request, report) do
    metadata = %{
      objective_id: field(request, :objective_id),
      step_id: field(request, :step_id),
      user_id: field(request, :user_id),
      ticker: field(request, :ticker),
      analysis_date: field(request, :analysis_date),
      engine: "both",
      trace_id: field(request, :trace_id),
      request_id: field(request, :request_id),
      parity_pass: get_in(report, [:parity_diff, "parity_pass"])
    }

    case Signal.new(
           "allbert.stocksage.native.parity_run.completed",
           AllbertSignals.redact(metadata),
           source: "/allbert/stocksage/native",
           subject: field(request, :user_id)
         ) do
      {:ok, signal} -> AllbertSignals.log(signal)
      _other -> :ok
    end
  rescue
    _exception -> :ok
  end

  defp json_safe(value) do
    value
    |> AllbertSignals.redact()
    |> to_json_safe()
  end

  defp to_json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_json_safe(%Date{} = value), do: Date.to_iso8601(value)
  defp to_json_safe(%Time{} = value), do: Time.to_iso8601(value)

  defp to_json_safe(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      Map.put(acc, json_key(key), to_json_safe(nested))
    end)
  end

  defp to_json_safe(value) when is_list(value), do: Enum.map(value, &to_json_safe/1)
  defp to_json_safe(value) when is_tuple(value), do: inspect(value)

  defp to_json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp to_json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp to_json_safe(nil), do: nil
  defp to_json_safe(value), do: inspect(value, limit: 20, printable_limit: 1_000)

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: inspect(key)

  defp drop_nil_values(map) when is_map(map) do
    Enum.reject(map, fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
