defmodule AllbertAssist.Workflows.ExpanderTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Workflows

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths_config = Application.get_env(:allbert_assist, AllbertAssist.Paths)
    home = Path.join(System.tmp_dir!(), "allbert-expander-#{System.unique_integer([:positive])}")
    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, AllbertAssist.Paths, home: home)
    File.mkdir_p!(Path.join(home, "workflows"))

    on_exit(fn ->
      restore_env("ALLBERT_HOME", original_home)
      restore_app_env(AllbertAssist.Paths, original_paths_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "expands workflow inputs and preserves step-output references", %{home: home} do
    copy_fixture!("multi_step", home)

    assert {:ok, expanded} =
             Workflows.expand("multi_step", %{since: "today"}, %{user_id: "local"})

    assert expanded.step_count == 3

    assert [%{action_params: %{"text" => "List issues since today."}}, second | _] =
             expanded.steps

    assert second.action_params["text"] == "Summarize ${steps.collect.issues}."
    assert expanded.preview.step_count == 3
    assert hd(expanded.preview.authority_gates).gate == :workflow_run_start
  end

  test "expands v0.46 research delegate workflow fixture", %{home: home} do
    copy_fixture!("research_delegate", home, version: "v0.46")

    assert {:ok, expanded} =
             Workflows.expand(
               "research_delegate",
               %{topic: "delegate orchestration"},
               %{user_id: "local"}
             )

    assert [
             %{
               kind: "delegate_agent",
               provider: "plan_build",
               delegate_agent_id: "research.specialist",
               candidate_action: "delegate_agent",
               action_params: %{
                 command: "research",
                 params: %{"topic" => "delegate orchestration", "max_sources" => 1}
               }
             }
           ] = expanded.steps

    assert [preview_step] = expanded.preview.steps
    assert preview_step.kind == :delegate_agent
    assert preview_step.action_name == "delegate_agent"
    assert preview_step.subagent_target == "research.specialist"
  end

  defp copy_fixture!(id, home, opts \\ []) do
    version = Keyword.get(opts, :version, "v0.44")

    File.cp!(
      Path.expand("../../fixtures/#{version}/workflows/#{id}.yaml", __DIR__),
      Path.join([home, "workflows", "#{id}.yaml"])
    )
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
