defmodule StockSage.Proposer do
  @moduledoc """
  Deterministic StockSage objective step proposer.

  The proposer only creates step attributes for the objective engine. It does
  not call the bridge, create confirmations, or write StockSage domain rows.
  """

  @behaviour AllbertAssist.Objectives.ProposerBehaviour

  @stopwords MapSet.new(~w[
    ANALYZE ANALYSIS ANALYSE COMPARE WITH AND TO THE FOR A AN RUN STOCK STOCKS
    TICKER TICKERS VS VERSUS PLEASE EXPLAIN MARKET MARKETS
  ])

  @impl true
  def propose(intent_decision, context) do
    text = text(intent_decision, context)
    hint = proposer_hint(context)

    case {parse_tickers(text), hint} do
      {[single], nil} ->
        {:ok, [run_analysis_step(single, context)], :done}

      {[first, second], nil} ->
        {:ok, [run_analysis_step(first, context)],
         {:more,
          {:stocksage,
           %{
             "step_index" => 1,
             "completed_steps" => [],
             "total_planned" => 2,
             "remaining_tickers" => [second],
             "force_stub" => field(context, :force_stub)
           }}}}

      {_tickers, {:stocksage, %{} = state}} ->
        continue_from_hint(state, context)

      {[], nil} ->
        {:no_steps, :no_tickers_recognized}

      {_too_many, nil} ->
        {:no_steps, :too_many_tickers_in_one_prompt}
    end
  end

  def parse_tickers(text) when is_binary(text) do
    ~r/\b[A-Z][A-Z0-9._-]{0,9}\b/
    |> Regex.scan(String.upcase(text))
    |> Enum.map(&List.first/1)
    |> Enum.reject(&MapSet.member?(@stopwords, &1))
    |> Enum.uniq()
    |> Enum.take(3)
  end

  def parse_tickers(_text), do: []

  def run_analysis_step(ticker, context, opts \\ []) do
    action_params =
      %{
        ticker: ticker,
        analysis_date: analysis_date(context),
        user_id: field(context, :user_id),
        force_stub: field(context, :force_stub)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{
      kind: "action",
      status: "proposed",
      stage: "propose_steps",
      provider: inspect(__MODULE__),
      candidate_action: "StockSage.Actions.RunAnalysis",
      parent_step_id: Keyword.get(opts, :parent_step_id),
      action_params: action_params,
      resource_access: [],
      result_summary: nil
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp continue_from_hint(%{"remaining_tickers" => [ticker | _rest]} = state, context) do
    parent_step_id =
      state
      |> Map.get("completed_steps", [])
      |> List.wrap()
      |> List.last()

    context = Map.put(context, :force_stub, Map.get(state, "force_stub"))

    {:ok, [run_analysis_step(ticker, context, parent_step_id: parent_step_id)], :done}
  end

  defp continue_from_hint(%{remaining_tickers: [ticker | _rest]} = state, context) do
    parent_step_id =
      state
      |> Map.get(:completed_steps, [])
      |> List.wrap()
      |> List.last()

    context = Map.put(context, :force_stub, Map.get(state, :force_stub))

    {:ok, [run_analysis_step(ticker, context, parent_step_id: parent_step_id)], :done}
  end

  defp continue_from_hint(_state, _context), do: {:no_steps, :no_tickers_remaining}

  defp text(intent_decision, context) do
    field(intent_decision, :text) ||
      field(intent_decision, :source_text) ||
      get_in_field(intent_decision, [:trace_metadata, :source_text]) ||
      field(context, :text) ||
      field(context, :source_text) ||
      get_in_field(context, [:request, :text]) ||
      ""
  end

  defp proposer_hint(context) do
    case field(context, :proposer_hint) do
      nil -> nil
      {:stocksage, %{} = state} -> {:stocksage, state}
      %{} = hint -> normalize_hint(hint)
      _other -> nil
    end
  end

  defp normalize_hint(%{"app_id" => "stocksage", "state" => %{} = state}), do: {:stocksage, state}
  defp normalize_hint(%{app_id: :stocksage, state: %{} = state}), do: {:stocksage, state}
  defp normalize_hint(_hint), do: nil

  defp analysis_date(context) do
    case field(context, :analysis_date) do
      %Date{} = date -> Date.to_iso8601(date)
      value when is_binary(value) and value != "" -> value
      _other -> Date.utc_today() |> Date.to_iso8601()
    end
  end

  defp get_in_field(value, keys) do
    Enum.reduce_while(keys, value, fn key, acc ->
      case field(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp field(%_struct{} = struct, key), do: Map.get(struct, key)

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil
end
