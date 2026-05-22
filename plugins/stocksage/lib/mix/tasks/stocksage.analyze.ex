defmodule Mix.Tasks.Stocksage.Analyze do
  @moduledoc """
  Request a StockSage analysis through the native engine or explicit Python bridge.

      mix stocksage.analyze TICKER ANALYSIS_DATE [--user USER] [--engine ENGINE] [--queue-id QUEUE_ID]

  Examples:

      mix stocksage.analyze AAPL 2026-05-01 --user local
      mix stocksage.analyze TSLA 2026-05-14 --queue-id queue_abc123

  The first invocation creates a durable confirmation record and prints the
  confirmation id. Approve it with:

      mix allbert.confirmations approve <confirmation-id> --reason "..."
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Request a StockSage analysis"
  @switches [
    user: :string,
    operator: :string,
    engine: :string,
    evidence_mode: :string,
    compare_python: :boolean,
    force_stub: :boolean,
    queue_id: :string,
    thread_id: :string,
    session_id: :string
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch([ticker, analysis_date | rest])
       when is_binary(ticker) and is_binary(analysis_date) do
    {opts, [], invalid} = OptionParser.parse(rest, switches: @switches)

    with :ok <- reject_invalid(invalid),
         {:ok, user_id} <- resolve_user(opts) do
      params =
        %{
          ticker: ticker,
          analysis_date: analysis_date,
          user_id: user_id,
          engine: Keyword.get(opts, :engine),
          evidence_mode: Keyword.get(opts, :evidence_mode),
          compare_python: Keyword.get(opts, :compare_python),
          force_stub: Keyword.get(opts, :force_stub),
          queue_entry_id: Keyword.get(opts, :queue_id),
          thread_id: Keyword.get(opts, :thread_id),
          session_id: Keyword.get(opts, :session_id)
        }
        |> drop_nil()

      Runner.run("run_analysis", params, context(user_id))
    end
  end

  defp dispatch(_args), do: {:error, :usage}

  defp context(user_id) do
    %{
      request: %{
        channel: :cli,
        user_id: user_id,
        operator_id: user_id,
        app_id: :stocksage,
        active_app: :stocksage
      },
      channel: :cli,
      actor: user_id,
      surface: "cli",
      app_id: :stocksage,
      active_app: :stocksage
    }
  end

  defp drop_nil(map) do
    Enum.reject(map, fn {_k, v} -> is_nil(v) end) |> Map.new()
  end

  defp print_result({:ok, %{status: :needs_confirmation} = response}) do
    confirmation = Map.get(response, :confirmation, %{})
    params_summary = Map.get(confirmation, "params_summary", %{})

    Mix.shell().info("StockSage analysis confirmation required.")
    Mix.shell().info("Confirmation id: #{response.confirmation_id}")
    Mix.shell().info("Ticker: #{params_summary["ticker"]}")
    Mix.shell().info("Analysis date: #{params_summary["analysis_date"]}")
    Mix.shell().info("Engine: #{params_summary["engine"]}")

    # v0.22 audit closeout (Gap 1 — stub-mode visibility): warn loudly
    # before approval so operators don't accidentally approve a stub-mode
    # request thinking they're getting a real TradingAgents run.
    if params_summary["force_stub"] == true do
      Mix.shell().info("Stub: true (force_stub set; approval will NOT call real TradingAgents)")
    end

    Mix.shell().info("""
    Approve with:
      mix allbert.confirmations approve #{response.confirmation_id} --reason "..."
    """)
  end

  defp print_result({:ok, %{status: :completed} = response}) do
    Mix.shell().info("StockSage analysis completed.")
    Mix.shell().info("Analysis id: #{response.analysis_id}")
    Mix.shell().info("Ticker: #{response.ticker}")
    Mix.shell().info("Analysis date: #{response.analysis_date}")
    Mix.shell().info("Engine: #{response.engine}")

    if Map.get(response, :bridge_duration_ms) do
      Mix.shell().info("Bridge duration ms: #{response.bridge_duration_ms}")
    end

    if Map.has_key?(response, :truncated) do
      Mix.shell().info("Truncated: #{response.truncated}")
    end

    # v0.22 audit closeout (Gap 1 — stub-mode visibility): always print
    # the stub flag on completed runs so operator inspection makes the
    # source unmistakable. `true` = bridge ran in `force_stub: true` mode
    # (no real TradingAgents call); `false` = real run.
    if Map.has_key?(response, :stub) do
      Mix.shell().info("Stub: #{response.stub}")
    end

    if is_map(Map.get(response, :parity_diff)) do
      Mix.shell().info("Parity pass: #{response.parity_diff["parity_pass"]}")
      Mix.shell().info("Rating agreement: #{response.parity_diff["rating_agreement"]}")
    end

    Mix.shell().info("Summary: #{response.summary}")
  end

  defp print_result({:ok, %{status: status, error: :bridge_disabled}}) do
    Mix.raise("""
    StockSage analysis is unavailable: bridge is disabled.
    Run `mix allbert.settings set stocksage.bridge_enabled true` to re-enable.
    (status=#{status})
    """)
  end

  defp print_result({:ok, %{status: :error, error: error, message: message}}) do
    Mix.raise("StockSage analysis error (#{inspect(error)}): #{message}")
  end

  defp print_result({:ok, %{status: status, message: message}}) do
    Mix.raise("StockSage analysis #{status}: #{message}")
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

  defp normalize_user(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Error shapes formatted here come from three callers in this module:
  # `dispatch/1` → `{:error, :usage}`, `reject_invalid/1` →
  # `{:error, {:invalid_options, _}}`, `resolve_user/1` →
  # `{:error, {:user_operator_mismatch, _, _}}`. Dialyzer flagged a
  # variable-pattern catch-all as dead; if a new error shape is added
  # to a caller, add a clause here too (or runtime will raise a
  # FunctionClauseError with the offending shape).
  defp format_reason(:usage) do
    """
    Usage:
      mix stocksage.analyze TICKER ANALYSIS_DATE [--user USER] [--engine ENGINE] [--queue-id QUEUE_ID]
    """
  end

  defp format_reason({:invalid_options, invalid}), do: "invalid options #{inspect(invalid)}"

  defp format_reason({:user_operator_mismatch, user, operator}),
    do: "--user #{user} differs from --operator #{operator}"
end
