unless Code.ensure_loaded?(AllbertAssist.Umbrella.MixProject) and
         function_exported?(AllbertAssist.Umbrella.MixProject, :project, 0) do
  Code.require_file(Path.expand("../../../../../mix.exs", __DIR__))
end

defmodule AllbertAssist.Pack.ApplicationBoundaryTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Umbrella.MixProject

  test "composition is a descriptorless Pack host with an OTP owner and only downward dependencies" do
    spec = Application.spec(:allbert_composition)
    applications = Keyword.fetch!(spec, :applications)
    env = Keyword.get(spec, :env, [])

    assert :allbert_kernel in applications
    assert :allbert_assist in applications
    refute :allbert_assist_web in applications
    refute Keyword.has_key?(env, :allbert_pack)
    assert Keyword.fetch!(spec, :mod) == {AllbertComposition.Application, []}
  end

  test "release starts kernel, residual, each pack, composition, then Web" do
    applications =
      MixProject.project()
      |> Keyword.fetch!(:releases)
      |> Keyword.fetch!(:allbert)
      |> Keyword.fetch!(:applications)

    # Order follows the R0 frozen DAG: kernel and residual first, then each
    # extracted pack, then the composition host, then Web. v1.4 M9 added
    # allbert_notes_files as the first pack to leave plugins/; M12 added telegram
    # and email, which take registry_order 300 and 400 and sit between it and the
    # host for the same reason.
    # v1.4 M13 completed the extraction: fifteen applications in R0 DAG order --
    # kernel, residual, the eleven packs composition depends on, the host, Web,
    # then the two packs that contribute web surfaces and therefore sit above it.
    assert applications == [
             allbert_kernel: :permanent,
             allbert_assist: :permanent,
             allbert_notes_files: :permanent,
             allbert_telegram: :permanent,
             allbert_email: :permanent,
             allbert_research: :permanent,
             allbert_browser: :permanent,
             allbert_discord: :permanent,
             allbert_matrix: :permanent,
             allbert_signal: :permanent,
             allbert_slack: :permanent,
             allbert_tui: :permanent,
             allbert_whatsapp: :permanent,
             allbert_artifacts: :permanent,
             stocksage: :permanent,
             allbert_composition: :permanent,
             allbert_assist_web: :permanent
           ]
  end

  # v1.4 M13.2 added the ambient load, and it has to come FIRST: it is only
  # useful before any application starts, and `prepare_test_database/1` runs a
  # Mix task that starts the residual. Order is the whole contract here, so the
  # assertion pins the order rather than merely tolerating an extra step.
  test "composition owner tests load the applications above Web, then prepare the residual database, before boot" do
    aliases =
      AllbertComposition.MixProject.project()
      |> Keyword.fetch!(:aliases)

    assert ["compile", load_ambient, prepare_database, "test"] = Keyword.fetch!(aliases, :test)
    assert is_function(load_ambient, 1)
    assert is_function(prepare_database, 1)
  end
end
