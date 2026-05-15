defmodule Mix.Tasks.Stocksage.ImportSqlite do
  @moduledoc """
  Import a legacy StockSage SQLite database.

      mix stocksage.import_sqlite PATH [--user USER] [--operator USER] [--dry-run] [--limit N]
  """

  use Mix.Task

  alias AllbertAssist.Actions.Runner

  @shortdoc "Import a legacy StockSage SQLite database"
  @switches [user: :string, operator: :string, dry_run: :boolean, limit: :integer]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(args) do
    {opts, rest, invalid} = OptionParser.parse(args, switches: @switches)

    with :ok <- reject_invalid(invalid),
         {:ok, path} <- single_path(rest),
         {:ok, user_id} <- resolve_user(opts),
         {:ok, response} <-
           run_action(
             "import_stocksage_sqlite",
             %{
               path: path,
               user_id: user_id,
               dry_run: Keyword.get(opts, :dry_run, false),
               limit: Keyword.get(opts, :limit)
             },
             user_id
           ) do
      {:ok, response.import}
    end
  end

  defp run_action(action, params, user_id) do
    case Runner.run(action, params, context(user_id)) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, Map.get(response, :error, :action_failed)}
    end
  end

  defp context(user_id) do
    %{request: %{channel: :cli, user_id: user_id, operator_id: user_id, app_id: :stocksage}}
  end

  defp print_result({:ok, result}) do
    Mix.shell().info("StockSage import")
    Mix.shell().info("Source: #{result.source_path}")
    Mix.shell().info("User: #{result.user_id}")
    Mix.shell().info("Dry run: #{result.dry_run}")

    Enum.each(~w[analyses analysis_details outcomes memory_entries], fn entity ->
      count = Map.fetch!(result.counts, entity)

      Mix.shell().info(
        "#{entity}: inserted=#{count.inserted} updated=#{count.updated} skipped=#{count.skipped} invalid=#{count.invalid}"
      )
    end)

    Enum.each(result.warnings, &Mix.shell().info("Warning: #{&1}"))
    Mix.shell().info("Warnings: #{length(result.warnings)}")
    Mix.shell().info("Elapsed ms: #{result.elapsed_ms}")
  end

  defp print_result({:error, reason}) do
    Mix.raise("StockSage import failed: #{format_reason(reason)}")
  end

  defp reject_invalid([]), do: :ok
  defp reject_invalid(invalid), do: {:error, {:invalid_options, invalid}}

  defp single_path([path]), do: {:ok, path}
  defp single_path([]), do: {:error, :missing_path}
  defp single_path(_rest), do: {:error, :too_many_paths}

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

  defp format_reason({:invalid_options, invalid}), do: "invalid options #{inspect(invalid)}"
  defp format_reason({:not_found, path}), do: "source path not found: #{path}"
  defp format_reason({:remote_uri_not_allowed, uri}), do: "remote URI not allowed: #{uri}"
  defp format_reason(:action_failed), do: "StockSage import action failed"

  defp format_reason({:user_operator_mismatch, user, operator}),
    do: "--user #{user} differs from --operator #{operator}"

  defp format_reason(:missing_path), do: "path is required"
  defp format_reason(:too_many_paths), do: "exactly one path is required"
  defp format_reason(reason), do: inspect(reason)
end
