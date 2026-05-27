defmodule Mix.Tasks.Allbert.Gen.Support do
  @moduledoc false

  alias AllbertAssist.Templates.Scaffold

  @switches [target: :string, force: :boolean, description: :string, version: :string]
  @aliases [t: :target, f: :force]

  def run_pattern(pattern_id, args, usage) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {opts, [name], []} ->
        params = params(name, opts)

        case Scaffold.write(pattern_id, params,
               target: Keyword.get(opts, :target),
               force?: Keyword.get(opts, :force, false)
             ) do
          {:ok, result} ->
            print_success(result)

          {:error, {:target_exists, preview}} ->
            print_preview(preview)
            Mix.raise("Target already exists. Re-run with --force after reviewing the preview.")

          {:error, reason} ->
            Mix.raise("Template generation failed: #{inspect(reason)}")
        end

      {_opts, _argv, invalid} when invalid != [] ->
        Mix.raise("Unknown option(s): #{inspect(invalid)}\n\n#{usage}")

      _other ->
        Mix.raise(usage)
    end
  end

  defp params(name, opts) do
    %{"name" => name}
    |> put_optional("description", Keyword.get(opts, :description))
    |> put_optional("version", Keyword.get(opts, :version))
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp print_success(result) do
    Mix.shell().info("Generated #{result.pattern_id} scaffold.")
    Mix.shell().info("Target: #{result.target_root}")

    Mix.shell().info(
      "Live integration: #{if result.live_integration?, do: "supported", else: "not supported"}"
    )

    Mix.shell().info("Files:")

    Enum.each(result.files, fn file ->
      Mix.shell().info("  #{file.path} #{file.bytes} bytes")
    end)
  end

  defp print_preview(preview) do
    Mix.shell().info("Target exists: #{preview.target_root}")
    Mix.shell().info("Preview:")

    Enum.each(preview.files, fn file ->
      Mix.shell().info("  #{file.status} #{file.path} #{file.bytes} bytes")
    end)
  end
end
