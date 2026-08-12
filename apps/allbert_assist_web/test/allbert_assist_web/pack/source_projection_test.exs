defmodule AllbertAssist.Pack.SourceProjectionTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Licenses
  alias AllbertAssist.Pack.OTPMetadata
  alias AllbertAssist.Pack.OTPMetadata.ReleaseApplication
  alias AllbertAssist.Pack.OTPMetadata.ReleaseSpec
  alias AllbertAssist.Pack.Projection

  @allbert_applications [
    :allbert_kernel,
    :allbert_assist,
    :allbert_notes_files,
    :allbert_telegram,
    :allbert_email,
    :allbert_research,
    :allbert_browser,
    :allbert_discord,
    :allbert_matrix,
    :allbert_signal,
    :allbert_slack,
    :allbert_tui,
    :allbert_whatsapp,
    :allbert_composition,
    :allbert_assist_web,
    :allbert_artifacts,
    :stocksage
  ]
  @repo_root Path.expand("../../../../..", __DIR__)

  test "reviewed catalog reconciles with every code-path Allbert application record" do
    assert {:ok, catalog} = Licenses.load_catalog(repo_root: @repo_root)

    applications =
      Enum.map(@allbert_applications, fn application ->
        assert Application.load(application) in [
                 :ok,
                 {:error, {:already_loaded, application}}
               ]

        path =
          application
          |> :code.lib_dir()
          |> to_string()
          |> Path.join("ebin/#{application}.app")

        assert {:ok, metadata} = OTPMetadata.read_app(path)
        metadata
      end)

    allbert_dependencies =
      Map.new(applications, fn application ->
        dependencies =
          application.applications
          |> Enum.filter(&(&1 in @allbert_applications))
          |> MapSet.new()

        {application.application, dependencies}
      end)

    assert allbert_dependencies == %{
             allbert_artifacts:
               MapSet.new([:allbert_assist, :allbert_assist_web, :allbert_kernel]),
             allbert_assist: MapSet.new([:allbert_kernel]),
             allbert_assist_web: MapSet.new([:allbert_assist, :allbert_composition]),
             allbert_browser: MapSet.new([:allbert_assist, :allbert_kernel, :allbert_research]),
             allbert_composition:
               MapSet.new([
                 :allbert_assist,
                 :allbert_browser,
                 :allbert_discord,
                 :allbert_email,
                 :allbert_kernel,
                 :allbert_matrix,
                 :allbert_notes_files,
                 :allbert_research,
                 :allbert_signal,
                 :allbert_slack,
                 :allbert_telegram,
                 :allbert_tui,
                 :allbert_whatsapp
               ]),
             allbert_discord: MapSet.new([:allbert_assist, :allbert_kernel]),
             allbert_email: MapSet.new([:allbert_assist, :allbert_kernel]),
             allbert_kernel: MapSet.new([]),
             allbert_matrix: MapSet.new([:allbert_assist, :allbert_kernel]),
             allbert_notes_files: MapSet.new([:allbert_assist, :allbert_kernel]),
             allbert_research: MapSet.new([:allbert_assist, :allbert_kernel]),
             allbert_signal: MapSet.new([:allbert_assist, :allbert_kernel]),
             allbert_slack: MapSet.new([:allbert_assist, :allbert_kernel]),
             allbert_telegram: MapSet.new([:allbert_assist, :allbert_kernel]),
             allbert_tui: MapSet.new([:allbert_assist, :allbert_kernel]),
             allbert_whatsapp: MapSet.new([:allbert_assist, :allbert_kernel]),
             stocksage: MapSet.new([:allbert_assist, :allbert_assist_web, :allbert_kernel])
           }

    release = %ReleaseSpec{
      name: "allbert",
      version: List.first(applications).version,
      erts_version: System.otp_release(),
      applications:
        Enum.map(applications, fn application ->
          %ReleaseApplication{
            application: application.application,
            version: application.version,
            start_mode: :permanent,
            included_applications: []
          }
        end)
    }

    assert {:ok, projection} =
             Projection.reconcile(catalog["components"], applications, release,
               closed_applications: @allbert_applications
             )

    assert Enum.map(projection, &{&1.application, &1.registry_order}) == [
             {:allbert_kernel, 0},
             {:allbert_assist, 100},
             {:allbert_notes_files, 200},
             {:allbert_telegram, 300},
             {:allbert_email, 400},
             {:allbert_research, 500},
             {:allbert_browser, 600},
             {:allbert_discord, 700},
             {:allbert_matrix, 800},
             {:allbert_signal, 900},
             {:allbert_slack, 1000},
             {:allbert_tui, 1100},
             {:allbert_whatsapp, 1200},
             {:allbert_artifacts, 1300},
             {:stocksage, 1400}
           ]
  end
end
