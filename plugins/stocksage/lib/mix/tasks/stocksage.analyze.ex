defmodule Mix.Tasks.Stocksage.Analyze do
  @moduledoc """
  Request a StockSage analysis through the Python bridge.

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

  @shortdoc "Request a StockSage analysis through the supervised Python bridge"
  @switches [
    user: :string,
    operator: :string,
    engine: :string,
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
      request: %{channel: :cli, user_id: user_id, operator_id: user_id, app_id: :stocksage},
      channel: :cli,
      actor: user_id,
      surface: "cli",
      app_id: :stocksage
    }
  end

  defp drop_nil(map) do
    Enum.reject(map, fn {_k, v} -> is_nil(v) end) |> Map.new()
  end

  defp print_result({:ok, %{status: :needs_confirmation} = response}) do
    confirmation = Map.get(response, :confirmation, %{})

    Mix.shell().info("StockSage analysis confirmation required.")
    Mix.shell().info("Confirmation id: #{response.confirmation_id}")
    Mix.shell().info("Ticker: #{Map.get(confirmation, "params_summary", %{})["ticker"]}")

    Mix.shell().info(
      "Analysis date: #{Map.get(confirmation, "params_summary", %{})["analysis_date"]}"
    )

    Mix.shell().info("Engine: #{Map.get(confirmation, "params_summary", %{})["engine"]}")

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

    if Map.has_key?(response, :bridge_duration_ms) do
      Mix.shell().info("Bridge duration ms: #{response.bridge_duration_ms}")
    end

    if Map.has_key?(response, :truncated) do
      Mix.shell().info("Truncated: #{response.truncated}")
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

  defp format_reason(:usage) do
    """
    Usage:
      mix stocksage.analyze TICKER ANALYSIS_DATE [--user USER] [--engine ENGINE] [--queue-id QUEUE_ID]
    """
  end

  defp format_reason({:invalid_options, invalid}), do: "invalid options #{inspect(invalid)}"

  defp format_reason({:user_operator_mismatch, user, operator}),
    do: "--user #{user} differs from --operator #{operator}"

  defp format_reason(reason), do: inspect(reason)
end
