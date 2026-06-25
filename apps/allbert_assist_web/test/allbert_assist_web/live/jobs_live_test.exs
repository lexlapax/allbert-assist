defmodule AllbertAssistWeb.JobsLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface.Catalog
  alias AllbertAssist.Trace

  setup do
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    root = Path.join(System.tmp_dir!(), "allbert-jobs-live-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Memory, root: Path.join(root, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        {:ok,
         %{
           message: "Live jobs response: #{request.text}",
           status: :completed,
           actions: [%{name: "direct_answer", status: :completed}]
         }}
      end
    )

    on_exit(fn ->
      restore_env(Memory, original_memory_config)
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "renders jobs and delegates run/pause/resume to contexts", %{conn: conn} do
    assert {:ok, job} =
             Jobs.create_job(%{
               name: "live brief",
               target_type: "runtime_prompt",
               target: %{text: "Run from LiveView."},
               schedule: %{kind: "manual"},
               user_id: "local"
             })

    {:ok, view, html} = live(conn, ~p"/jobs")

    assert html =~ "Scheduled Jobs"
    assert has_element?(view, "#operator-shell[data-active-page='jobs']")
    assert has_element?(view, "#jobs-catalog-renderer[data-workspace-renderer='surface']")
    assert has_element?(view, "#job-#{job.id}[data-workspace-component='job_card']")
    assert has_element?(view, "#run-#{job.id}[data-workspace-component='button']")
    assert_catalog_components_known!(html)
    refute html =~ "<table"
    assert html =~ "live brief"
    assert html =~ job.id
    assert html =~ "status=paused" or html =~ ">paused<"

    view
    |> element("#resume-#{job.id}")
    |> render_click()

    assert Repo.reload!(job).status == "active"
    assert render(view) =~ "Resumed live brief"

    view
    |> element("#run-#{job.id}")
    |> render_click()

    html = render(view)
    assert html =~ "status=completed"
    assert html =~ "trigger=manual"
    refute html =~ "Approval:  status= target="

    view
    |> element("#pause-#{job.id}")
    |> render_click()

    assert Repo.reload!(job).status == "paused"
    assert render(view) =~ "Paused live brief"
  end

  test "blocked jobs keep run and resume actions behind the confirmation", %{conn: conn} do
    assert {:ok, confirmation} = create_pending_confirmation("conf_live_blocked_job")

    assert {:ok, job} =
             Jobs.create_job(%{
               name: "blocked live",
               target_type: "runtime_prompt",
               target: %{text: "Fetch https://example.com"},
               schedule: %{kind: "manual"},
               user_id: "local"
             })

    assert {:ok, blocked_job} =
             job
             |> Job.changeset(%{
               status: "blocked",
               blocked_confirmation_id: confirmation["id"],
               next_due_at: nil
             })
             |> Repo.update()

    {:ok, view, html} = live(conn, ~p"/jobs")
    assert has_element?(view, "#operator-shell[data-active-page='jobs']")
    assert has_element?(view, "#job-#{blocked_job.id}[data-workspace-component='job_card']")
    assert_catalog_components_known!(html)
    assert html =~ "blocked live"
    assert html =~ "confirmation conf_live_blocked_job"

    view
    |> element("#resume-#{blocked_job.id}")
    |> render_click()

    assert render(view) =~ "mix allbert.confirmations show conf_live_blocked_job"
    assert Repo.reload!(blocked_job).status == "blocked"

    view
    |> element("#run-#{blocked_job.id}")
    |> render_click()

    assert render(view) =~ "mix allbert.confirmations show conf_live_blocked_job"
    assert [] = Jobs.list_runs(blocked_job)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp create_pending_confirmation(id) do
    Confirmations.create(%{
      id: id,
      origin: %{
        actor: "local",
        channel: :job,
        surface: "/jobs"
      },
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"},
      resume_params_ref: %{url: "https://example.com"}
    })
  end

  defp assert_catalog_components_known!(html) do
    known_components = Catalog.known_components() |> Enum.map(&Atom.to_string/1)

    rendered_components =
      ~r/data-workspace-component="([^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert rendered_components != []
    assert Enum.all?(rendered_components, &(&1 in known_components))
  end
end
