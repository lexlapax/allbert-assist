unless Code.ensure_loaded?(AllbertAssist.Umbrella.MixProject) and
         function_exported?(AllbertAssist.Umbrella.MixProject, :project, 0) do
  Code.require_file(Path.expand("../../../../../mix.exs", __DIR__))
end

defmodule AllbertAssist.Pack.ApplicationBoundaryTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Umbrella.MixProject

  test "composition is a descriptorless host with only downward Allbert dependencies" do
    spec = Application.spec(:allbert_composition)
    applications = Keyword.fetch!(spec, :applications)
    env = Keyword.get(spec, :env, [])

    assert :allbert_kernel in applications
    assert :allbert_assist in applications
    refute :allbert_assist_web in applications
    refute Keyword.has_key?(env, :allbert_pack)
    assert Keyword.get(spec, :mod) in [nil, []]
  end

  test "release starts kernel, residual, composition, then Web" do
    applications =
      MixProject.project()
      |> Keyword.fetch!(:releases)
      |> Keyword.fetch!(:allbert)
      |> Keyword.fetch!(:applications)

    assert applications == [
             allbert_kernel: :permanent,
             allbert_assist: :permanent,
             allbert_composition: :permanent,
             allbert_assist_web: :permanent
           ]
  end

  test "composition owner tests prepare the residual database before boot" do
    aliases =
      AllbertComposition.MixProject.project()
      |> Keyword.fetch!(:aliases)

    assert [prepare_database, "test"] = Keyword.fetch!(aliases, :test)
    assert is_function(prepare_database, 1)
  end
end
