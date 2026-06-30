defmodule Mix.Tasks.Allbert.Home.Import do
  @moduledoc """
  Dry-run validate an Allbert Home portability envelope.

  ## Usage

      mix allbert.home.import --dry-run --in /path/to/home.envelope.json
      mix allbert.home.import --dry-run --in /path/to/home.envelope.json --evidence-out /path/to/diagnostic.json
  """

  use Mix.Task

  alias AllbertAssist.Paths
  alias AllbertAssist.Portability.Import

  @shortdoc "Dry-run validate an Allbert Home portability envelope"

  @impl true
  def run(args) do
    # Dry-run import must not start the OTP app: supervisors and SQLite WAL/SHM
    # bookkeeping are target-Home writes even when no import state is applied.
    args
    |> parse!()
    |> dry_run!()
  end

  defp parse!(args) do
    case OptionParser.parse(args, strict: [dry_run: :boolean, in: :string, evidence_out: :string]) do
      {opts, [], []} ->
        input = Keyword.get(opts, :in)

        if Keyword.get(opts, :dry_run) == true and is_binary(input) and input != "" do
          %{in: input, evidence_out: Keyword.get(opts, :evidence_out)}
        else
          Mix.raise(usage())
        end

      {_opts, _rest, invalid} when invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      _other ->
        Mix.raise(usage())
    end
  end

  defp dry_run!(%{in: input, evidence_out: evidence_out}) do
    result = Import.dry_run(input)

    case result do
      {:ok, diagnostic} ->
        emit_diagnostic!(diagnostic, evidence_out)
        :ok

      {:error, diagnostic} ->
        emit_diagnostic!(diagnostic, evidence_out)
        Mix.raise("Home import dry-run blocked: #{diagnostic["message"]}")
    end
  end

  defp emit_diagnostic!(diagnostic, nil) do
    Mix.shell().info(Jason.encode!(diagnostic, pretty: true))
  end

  defp emit_diagnostic!(diagnostic, path) do
    validate_evidence_path!(path)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(diagnostic, pretty: true))
    Mix.shell().info("Dry-run diagnostic: #{path}")
    Mix.shell().info("status=#{diagnostic["status"]} applied=#{diagnostic["applied"]}")
  end

  defp validate_evidence_path!(path) do
    expanded = Path.expand(path)
    target_home = Paths.home() |> Path.expand() |> with_trailing_slash()

    if String.starts_with?(expanded, target_home) do
      Mix.raise("Evidence path must be outside the target Allbert Home.")
    end
  end

  defp with_trailing_slash(path), do: String.trim_trailing(path, "/") <> "/"

  defp usage do
    """
    Usage:
      mix allbert.home.import --dry-run --in PATH [--evidence-out PATH]
    """
  end
end
