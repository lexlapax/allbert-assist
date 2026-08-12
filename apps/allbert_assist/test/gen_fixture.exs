defmodule GenFixture do
  @project_root Path.expand("../../..", __DIR__)

  @source_roots [
    "apps/allbert_assist/lib",
    "apps/allbert_assist_web/lib",
    "apps/allbert_composition/lib",
    "apps/allbert_kernel/lib",
    "apps/allbert_notes_files/lib",
    "apps/allbert_telegram/lib",
    "apps/allbert_email/lib",
    "plugins/*/lib"
  ]

  @activation_carrier_definition "apps/allbert_kernel/lib/allbert_assist/pack/activation_guard.ex"

  def inventory_excluded?(path) do
    path in [
      "apps/allbert_kernel/lib/allbert_assist/pack/effect_guard.ex",
      @activation_carrier_definition
    ] or test_only_seam?(path)
  end

  def test_only_seam?(path) do
    project_path(path)
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&(String.starts_with?(String.trim_leading(&1), "#") or &1 == ""))
    |> List.first()
    |> Kernel.==("if Mix.env() == :test do")
  end

  def source_paths_matching(pattern) do
    @source_roots
    |> Enum.flat_map(fn root ->
      Path.wildcard(Path.join([project_root(), root, "**", "*.ex"]))
    end)
    |> Enum.filter(&(File.read!(&1) =~ pattern))
    |> Enum.map(&Path.relative_to(&1, project_root()))
    |> Enum.reject(&inventory_excluded?/1)
    |> Enum.sort()
  end

  def generate() do
    IO.puts("__DIR__: #{__DIR__}")
    IO.puts("Source roots: #{inspect(@source_roots)}")
    IO.puts("Project root: #{project_root()}")

    all_files = @source_roots
    |> Enum.flat_map(fn root ->
      Path.wildcard(Path.join([project_root(), root, "**", "*.ex"]))
    end)
    IO.puts("Total .ex files found: #{length(all_files)}")

    effect_guard = source_paths_matching(~r/\bEffectGuard\b/)
    activation_guard = source_paths_matching(~r/\bActivationGuard\./)
    epoch = source_paths_matching(~r/\ballbert_pack_epoch\b/)
    activation_rejection = source_paths_matching(~r/\ballbert_pack_activation\b/)
      |> Enum.filter(fn path ->
        File.read!(project_path(path)) =~ "{:error, :product_not_ready}"
      end)

    IO.puts("\nEffect Guard sources: #{length(effect_guard)}")
    IO.inspect(effect_guard, pretty: true, limit: :infinity)

    IO.puts("\nActivation Guard sources: #{length(activation_guard)}")
    IO.inspect(activation_guard, pretty: true, limit: :infinity)

    IO.puts("\nEpoch sources: #{length(epoch)}")
    IO.inspect(epoch, pretty: true, limit: :infinity)

    IO.puts("\nActivation rejection sources: #{length(activation_rejection)}")
    IO.inspect(activation_rejection, pretty: true, limit: :infinity)
  end

  defp project_path(path), do: Path.join(project_root(), path)
  defp project_root, do: @project_root
end

GenFixture.generate()
