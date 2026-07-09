defmodule AllbertAssist.CLI.Areas.Database do
  @moduledoc """
  Release-safe database maintenance commands.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Database
  alias AllbertAssist.Surfaces.ContextBuilder

  @usage """
  Usage:
    allbert admin db list-backups
    allbert admin db restore [latest|BACKUP_BASENAME|BACKUP_PATH] [--dry-run]
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    ctx = context || ContextBuilder.cli_context(surface: "allbert admin db")

    case route(argv, ctx) do
      {:ok, output} -> Render.ok(output)
      {:error, output} -> Render.error(output)
      :usage -> Render.usage(@usage)
    end
  end

  defp route(["list-backups"], _ctx) do
    lines =
      case Database.list_backups() do
        [] -> ["No database backups found."]
        backups -> ["Database backups:"] ++ Enum.map(backups, &"- #{Path.basename(&1)}")
      end

    {:ok, lines}
  end

  defp route(["restore" | rest], ctx) do
    {opts, args, invalid} = OptionParser.parse(rest, strict: [dry_run: :boolean])

    cond do
      invalid != [] ->
        {:error, "Invalid option: #{invalid |> hd() |> elem(0)}"}

      length(args) > 1 ->
        :usage

      true ->
        backup = List.first(args) || "latest"
        params = %{backup: backup, dry_run: Keyword.get(opts, :dry_run, false)}

        {:ok, result} = Runner.run("restore_database_backup", params, ctx)
        render_action(result)
    end
  end

  defp route(_args, _ctx), do: :usage

  defp render_action(%{status: :needs_confirmation} = result) do
    {:error,
     [
       result.message,
       "",
       "This command needs operator confirmation. Review and approve:",
       "  allbert admin confirmations list",
       "  allbert admin confirmations approve <ID>"
     ]}
  end

  defp render_action(%{status: :completed} = result), do: {:ok, result.message}
  defp render_action(%{message: message}), do: {:error, message}
end
