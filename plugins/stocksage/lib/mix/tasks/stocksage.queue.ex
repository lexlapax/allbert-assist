defmodule Mix.Tasks.Stocksage.Queue do
  @moduledoc """
  Manage local StockSage queue rows.

      mix stocksage.queue create SYMBOL [--user USER] [--operator USER] [--thread-id THREAD_ID]
      mix stocksage.queue list [--user USER] [--operator USER] [--status STATUS]
  """

  use Mix.Task

  alias StockSage.Queue

  @shortdoc "Create and inspect local StockSage queue rows"
  @switches [
    user: :string,
    operator: :string,
    thread_id: :string,
    session_id: :string,
    status: :string,
    priority: :string,
    requested_for: :string,
    limit: :integer
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["create", symbol | rest]) do
    {opts, [], invalid} = OptionParser.parse(rest, switches: @switches)

    with :ok <- reject_invalid(invalid),
         {:ok, user_id} <- resolve_user(opts) do
      Queue.create_entry(%{
        user_id: user_id,
        symbol: symbol,
        thread_id: Keyword.get(opts, :thread_id),
        session_id: Keyword.get(opts, :session_id),
        priority: Keyword.get(opts, :priority, "normal"),
        requested_for: parse_date(Keyword.get(opts, :requested_for)),
        request: %{"source" => "stocksage.queue.cli"}
      })
      |> case do
        {:ok, entry} -> {:ok, {:created, entry}}
        {:error, changeset} -> {:error, {:invalid_queue_entry, errors_on(changeset)}}
      end
    end
  end

  defp dispatch(["list" | rest]) do
    {opts, [], invalid} = OptionParser.parse(rest, switches: @switches)

    with :ok <- reject_invalid(invalid),
         {:ok, user_id} <- resolve_user(opts) do
      entries =
        Queue.list_entries(user_id,
          status: Keyword.get(opts, :status),
          limit: Keyword.get(opts, :limit, 50)
        )

      {:ok, {:list, user_id, entries}}
    end
  end

  defp dispatch(_args), do: {:error, :usage}

  defp print_result({:ok, {:created, entry}}) do
    Mix.shell().info("StockSage queue entry #{entry.id}")
    Mix.shell().info("User: #{entry.user_id}")
    Mix.shell().info("Symbol: #{entry.symbol}")
    Mix.shell().info("Status: #{entry.status}")
    Mix.shell().info("Priority: #{entry.priority}")
    Mix.shell().info("Requested for: #{format_value(entry.requested_for)}")
    Mix.shell().info("Inserted at: #{format_value(entry.inserted_at)}")
  end

  defp print_result({:ok, {:list, user_id, entries}}) do
    Mix.shell().info("StockSage queue for #{user_id}")
    Mix.shell().info("Returned: #{length(entries)}")

    Enum.each(entries, fn entry ->
      Mix.shell().info(
        "#{entry.id} #{entry.symbol} status=#{entry.status} priority=#{entry.priority} requested_for=#{format_value(entry.requested_for)} analysis_id=#{format_value(entry.analysis_id)} updated_at=#{format_value(entry.updated_at)}"
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

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(to_string(value)) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp format_reason(:usage) do
    """
    Usage:
      mix stocksage.queue create SYMBOL [--user USER] [--operator USER] [--thread-id THREAD_ID]
      mix stocksage.queue list [--user USER] [--operator USER] [--status STATUS]
    """
  end

  defp format_reason({:invalid_options, invalid}), do: "invalid options #{inspect(invalid)}"
  defp format_reason({:invalid_queue_entry, errors}), do: "invalid queue entry #{inspect(errors)}"

  defp format_reason({:user_operator_mismatch, user, operator}),
    do: "--user #{user} differs from --operator #{operator}"

  defp format_value(nil), do: "-"
  defp format_value(value), do: to_string(value)
end
