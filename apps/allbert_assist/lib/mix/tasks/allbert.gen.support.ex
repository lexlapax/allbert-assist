defmodule Mix.Tasks.Allbert.Gen.Support do
  @moduledoc false

  alias AllbertAssist.Templates.Scaffold

  @switches [
    target: :string,
    force: :boolean,
    smoke: :boolean,
    description: :string,
    version: :string,
    permission: :string,
    instruction: :string,
    schedule: :string,
    at: :string,
    timezone: :string,
    objective: :string,
    steps: :string,
    pattern: :string
  ]
  @aliases [t: :target, f: :force]

  def run_pattern(pattern_id, args, usage, opts \\ []) do
    ignore_opts = Keyword.get(opts, :ignore_opts, [])

    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {opts, [name], []} ->
        params = params(name, Keyword.drop(opts, [:target, :force, :smoke] ++ ignore_opts))

        case Scaffold.write(pattern_id, params,
               target: Keyword.get(opts, :target),
               smoke?: Keyword.get(opts, :smoke, false),
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

  def run_flow(args, usage) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {opts, [name], []} ->
        pattern_id = flow_pattern_id(Keyword.get(opts, :pattern, "flow"))
        params = params(name, Keyword.drop(opts, [:target, :force, :smoke, :pattern]))

        case Scaffold.write(pattern_id, params,
               target: Keyword.get(opts, :target),
               smoke?: Keyword.get(opts, :smoke, false),
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
    Enum.reduce(opts, %{"name" => name}, fn {key, value}, acc ->
      put_optional(acc, Atom.to_string(key), value)
    end)
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp flow_pattern_id("objective"), do: "objective"
  defp flow_pattern_id("flow"), do: "flow"
  defp flow_pattern_id(other), do: Mix.raise("Unsupported flow pattern: #{other}")

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
