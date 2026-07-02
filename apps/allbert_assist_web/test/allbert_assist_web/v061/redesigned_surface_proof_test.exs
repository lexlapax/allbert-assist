defmodule AllbertAssistWeb.V061.RedesignedSurfaceProofTest do
  @moduledoc """
  v0.61 M10.1 proof for redesigned live surfaces.

  These checks bind the rows that are too broad for a single page test: core live
  screens stay catalog-composed, Jobs/Objectives remain populated, no fallback
  renderer leaks into the promoted surface, and first-run suggestions are inert
  registered-action DTOs rather than authority-bearing controls.
  """
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.{Confirmations, Jobs, Objectives, Paths, Runtime, Session, Settings}
  alias AllbertAssist.Surface.Catalog

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-v061-surface-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        {:ok, %{message: "Runtime LiveView response: #{request.text}", status: :completed}}
      end
    )

    _ = Session.clear_active_app("local", "web-local")

    on_exit(fn ->
      _ = Session.clear_active_app("local", "web-local")
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "redesigned workspace, jobs, and objectives surfaces compose through the catalog",
       %{conn: conn} do
    assert {:ok, job} =
             Jobs.create_job(%{
               name: "v061 surface job",
               target_type: "runtime_prompt",
               target: %{text: "Run from proof."},
               schedule: %{kind: "manual"},
               user_id: "local"
             })

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "local",
               title: "v061 surface objective",
               objective: "Verify the redesigned objective surfaces.",
               status: "running",
               active_app: "allbert"
             })

    {:ok, workspace_view, workspace_html} = live(conn, ~p"/workspace")
    {:ok, jobs_view, jobs_html} = live(conn, ~p"/jobs")
    {:ok, objectives_view, objectives_html} = live(conn, ~p"/objectives")
    {:ok, objective_view, objective_html} = live(conn, ~p"/objectives/#{objective.id}")

    assert has_element?(workspace_view, "#workspace-renderer[data-workspace-renderer='surface']")
    assert has_element?(workspace_view, "#workspace-chat-region[data-workspace-component='chat']")
    assert has_element?(jobs_view, "#jobs-catalog-renderer[data-workspace-renderer='surface']")
    assert has_element?(jobs_view, "#job-#{job.id}[data-workspace-component='job_card']")

    assert has_element?(
             objectives_view,
             "#objectives-catalog-renderer[data-workspace-renderer='surface']"
           )

    assert has_element?(
             objectives_view,
             "#objective-index-#{objective.id}[data-workspace-component='objective_card']"
           )

    assert has_element?(
             objective_view,
             "#objective-header [data-workspace-component='objective_card']"
           )

    for html <- [workspace_html, jobs_html, objectives_html, objective_html] do
      assert_known_catalog_components!(html)
      refute html =~ "unknown workspace component"
      refute html =~ "data-placeholder-component"
    end

    refute jobs_html =~ "<table"
    assert objectives_html =~ "v061 surface objective"
    assert objective_html =~ "Verify the redesigned objective surfaces."

    IO.puts(
      "redesigned-screens-catalog-composed-001 status=pass surfaces=workspace,jobs,objectives"
    )

    IO.puts("redesign-no-new-rendering-path-001 status=pass renderer=workspace_catalog")
    IO.puts("jobs-objectives-no-regression-001 status=pass jobs=true objectives=true")
    IO.puts("catalog-rendering-boundary-preserved-001 status=pass known_components=true")
  end

  test "first-run suggested actions are view-only registered-action DTOs", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/workspace")

    assert has_element?(
             view,
             ".workspace-chat-empty[data-suggested-actions='view-only']"
           )

    actions =
      ~r/data-registered-action="([^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    # First-Model-Path shaped (ADR 0078): the empty-handed operator is led to set up
    # a first model before anything else.
    assert actions == ["model_doctor", "direct_answer", "list_objectives", "list_channels"]

    capabilities = Map.new(ActionsRegistry.capabilities(), &{&1.name, &1})

    for action <- actions do
      capability = Map.fetch!(capabilities, action)
      assert capability.permission == :read_only
      assert capability.confirmation == :not_required
    end

    for tag <- Regex.scan(~r/<article[^>]*class="workspace-suggested-action"[^>]*>/, html) do
      [article] = tag
      refute article =~ "phx-click"
      refute article =~ "phx-submit"
      refute article =~ "phx-value-action-name"
    end

    IO.puts("empty-state-suggested-action-view-only-001 status=pass controls=inert")
    IO.puts("suggested-action-dto-no-authority-001 status=pass actions=registered read_only=true")
  end

  defp assert_known_catalog_components!(html) do
    known_components = Catalog.known_components() |> Enum.map(&Atom.to_string/1)

    rendered_components =
      ~r/data-workspace-component="([^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert rendered_components != []
    assert Enum.all?(rendered_components, &(&1 in known_components))
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
