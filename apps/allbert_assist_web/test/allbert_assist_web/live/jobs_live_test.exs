defmodule AllbertAssistWeb.JobsLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Jobs
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
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

    view
    |> element("#pause-#{job.id}")
    |> render_click()

    assert Repo.reload!(job).status == "paused"
    assert render(view) =~ "Paused live brief"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
