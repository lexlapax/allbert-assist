defmodule Mix.Tasks.Allbert.Licenses do
  @moduledoc """
  Generate or verify the reviewed offline license union.

      mix allbert.licenses
      mix allbert.licenses --check

  `--root PATH` and `--catalog PATH` exist for deterministic fixtures and
  release tooling. This task never starts the Allbert runtime or uses a network.
  """

  use Mix.Task

  alias AllbertAssist.Licenses

  @shortdoc "Generate or check deterministic packaged-license inputs"
  @switches [check: :boolean, root: :string, catalog: :string]
  @repo_root Path.expand("../../../../..", __DIR__)

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        run_generation(opts)

      {_opts, _rest, invalid} when invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}\n\n#{usage()}")

      _other ->
        Mix.raise(usage())
    end
  end

  defp run_generation(opts) do
    root = opts |> Keyword.get(:root, @repo_root) |> Path.expand()

    generation_opts =
      [repo_root: root, check: Keyword.get(opts, :check, false)]
      |> maybe_put(:catalog_path, opts[:catalog])

    case Licenses.generate_repo(generation_opts) do
      {:ok, result} ->
        verb = if result.mode == :check, do: "verified", else: "generated"
        Mix.shell().info("License evidence #{verb}: #{result.path}")
        :ok

      {:error, error} ->
        Mix.raise(error.message)
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, Path.expand(value))

  defp usage do
    "Usage: mix allbert.licenses [--check] [--root PATH] [--catalog PATH]"
  end
end
