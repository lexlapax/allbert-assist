defmodule Mix.Tasks.Stocksage.Analyses do
  @moduledoc """
  Inspect local StockSage analyses.

      mix stocksage.analyses list [--user USER] [--operator USER] [--symbol SYMBOL]
      mix stocksage.analyses show ANALYSIS_ID [--user USER] [--operator USER]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "List or show local StockSage analyses"
  @switches [user: :string, operator: :string, symbol: :string, limit: :integer, offset: :integer]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list" | rest]) do
    {opts, [], invalid} = OptionParser.parse(rest, switches: @switches)

    with :ok <- reject_invalid(invalid),
         {:ok, user_id} <- resolve_user(opts),
         {:ok, response} <-
           run_action(
             "list_analyses",
             %{
               user_id: user_id,
               symbol: Keyword.get(opts, :symbol),
               limit: Keyword.get(opts, :limit, 50),
               offset: Keyword.get(opts, :offset, 0)
             },
             user_id
           ) do
      {:ok, {:list, user_id, response.analyses}}
    end
  end

  defp dispatch(["show", analysis_id | rest]) do
    {opts, [], invalid} = OptionParser.parse(rest, switches: @switches)

    with :ok <- reject_invalid(invalid),
         {:ok, user_id} <- resolve_user(opts),
         {:ok, response} <-
           run_action("show_analysis", %{user_id: user_id, analysis_id: analysis_id}, user_id) do
      case response.status do
        :completed -> {:ok, {:show, user_id, response.analysis}}
        :not_found -> {:error, {:not_found, analysis_id}}
      end
    end
  end

  defp dispatch(_args), do: {:error, :usage}

  defp run_action(action, params, user_id) do
    case Runner.run(action, params, context(user_id)) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, %{status: :not_found} = response} -> {:ok, response}
      {:ok, response} -> {:error, Map.get(response, :error, :action_failed)}
    end
  end

  defp context(user_id) do
    %{request: %{channel: :cli, user_id: user_id, operator_id: user_id, app_id: :stocksage}}
  end

  defp print_result({:ok, {:list, user_id, analyses}}) do
    Mix.shell().info("StockSage analyses for #{user_id}")
    Mix.shell().info("Returned: #{length(analyses)}")

    Enum.each(analyses, fn analysis ->
      Mix.shell().info(
        "#{analysis.id} #{analysis.symbol} status=#{analysis.status} source=#{analysis.source} recommendation=#{analysis.recommendation || "-"} score=#{format_value(analysis.score)} analysis_date=#{format_value(analysis.analysis_date)} updated_at=#{format_value(analysis.updated_at)}"
      )
    end)
  end

  defp print_result({:ok, {:show, user_id, analysis}}) do
    Mix.shell().info("StockSage analysis #{analysis.id}")
    Mix.shell().info("User: #{user_id}")
    Mix.shell().info("Symbol: #{analysis.symbol}")
    Mix.shell().info("Status: #{analysis.status}")
    Mix.shell().info("Source: #{analysis.source}")
    Mix.shell().info("Recommendation: #{format_value(analysis.recommendation)}")
    Mix.shell().info("Score: #{format_value(analysis.score)}")
    Mix.shell().info("Analysis date: #{format_value(analysis.analysis_date)}")
    Mix.shell().info("Summary: #{bounded(analysis.summary, 500)}")
    Mix.shell().info("Details: #{length(analysis.details)}")

    Enum.each(analysis.details, fn detail ->
      # v0.22 third-validation closeout (MED): print stub + truncated
      # from the persisted payload so the operator can immediately tell
      # which detail rows came from the deterministic stub path versus a
      # real TradingAgents propagate call. The payload may be empty for
      # legacy rows written before v0.22; `format_detail_meta/1` returns
      # an empty string in that case so legacy output is unchanged.
      meta = format_detail_meta(Map.get(detail, :payload) || %{})
      Mix.shell().info("- #{detail.section}#{meta}: #{bounded(detail.content, 240)}")
    end)

    Mix.shell().info("Outcomes: #{length(analysis.outcomes)}")

    Enum.each(analysis.outcomes, fn outcome ->
      Mix.shell().info(
        "- #{outcome.symbol} label=#{outcome.label} horizon_days=#{format_value(outcome.horizon_days)} return_pct=#{format_value(outcome.return_pct)}"
      )
    end)
  end

  defp print_result({:error, reason}), do: Mix.raise(format_reason(reason))

  defp reject_invalid([]), do: :ok
  defp reject_invalid(invalid), do: {:error, {:invalid_options, invalid}}

  defp resolve_user(opts) do
    user = normalize_user(Keyword.get(opts, :user))
    operator = normalize_user(Keyword.get(opts, :operator))

    cond do
      user && operator && user != operator -> {:error, {:user_operator_mismatch, user, operator}}
      user -> {:ok, user}
      operator -> {:ok, operator}
      true -> {:ok, "local"}
    end
  end

  defp normalize_user(nil), do: nil

  defp normalize_user(user) when is_binary(user) do
    case String.trim(user) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp format_reason(:usage) do
    """
    Usage:
      mix stocksage.analyses list [--user USER] [--operator USER] [--symbol SYMBOL]
      mix stocksage.analyses show ANALYSIS_ID [--user USER] [--operator USER]
    """
  end

  defp format_reason({:invalid_options, invalid}), do: "invalid options #{inspect(invalid)}"
  defp format_reason({:not_found, id}), do: "StockSage analysis not found: #{id}"
  defp format_reason(:action_failed), do: "StockSage analyses action failed"

  defp format_reason({:user_operator_mismatch, user, operator}),
    do: "--user #{user} differs from --operator #{operator}"

  defp format_reason(reason), do: inspect(reason)

  defp bounded(nil, _max), do: "-"

  defp bounded(value, max) do
    value = to_string(value)

    if String.length(value) > max do
      String.slice(value, 0, max) <> "..."
    else
      value
    end
  end

  defp format_value(nil), do: "-"
  defp format_value(value), do: to_string(value)

  # Render the small set of operator-facing payload fields the bridge
  # writes (`engine`, `truncated`, `stub`). Anything else in the payload
  # is intentionally omitted from the CLI so an oversized or surprising
  # payload key never leaks into the operator's terminal. Order is
  # stable for predictable diffs in operator smoke transcripts.
  defp format_detail_meta(payload) when is_map(payload) do
    [
      maybe_meta(payload, "stub", "stub"),
      maybe_meta(payload, "truncated", "truncated"),
      maybe_meta(payload, "engine", "engine")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      parts -> " (" <> Enum.join(parts, ", ") <> ")"
    end
  end

  defp format_detail_meta(_payload), do: ""

  defp maybe_meta(payload, key, label) do
    case Map.fetch(payload, key) do
      {:ok, value} -> "#{label}=#{value}"
      :error -> nil
    end
  end
end
