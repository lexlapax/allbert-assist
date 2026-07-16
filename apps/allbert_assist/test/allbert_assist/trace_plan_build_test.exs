defmodule AllbertAssist.TracePlanBuildTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Trace

  test "trace text includes bounded Plan Preview section" do
    trace = Trace.text(turn())

    assert trace =~ "## Plan Preview"
    assert trace =~ "- Workflow: multi_step"
    assert trace =~ "- Version: 1"
    assert trace =~ "- Step count: 1"
    assert trace =~ "direct_answer permission=read_only confirmation=false"
    assert trace =~ "workflow_run_start scope=workflow://multi_step"
  end

  defp turn do
    %{
      request: %{
        text: "run workflow multi_step",
        channel: :test,
        operator_id: "local",
        user_id: "local",
        metadata: %{}
      },
      input_signal: %{id: "sig_in", type: "allbert.test"},
      response_signal: %{id: "sig_out", type: "allbert.response"},
      response: %{
        status: :needs_confirmation,
        message: "Plan run requires approval.",
        actions: [],
        output_data: %{
          preview: %{
            workflow_id: "multi_step",
            workflow_version: 1,
            objective_title: "Multi-step read-only workflow.",
            step_count: 1,
            authority_gates: [
              %{ordinal: 0, gate: :workflow_run_start, scope: "workflow://multi_step"}
            ],
            steps: [
              %{
                ordinal: 1,
                kind: :action,
                action_name: "direct_answer",
                permission: :read_only,
                confirmations_required: false
              }
            ]
          }
        }
      }
    }
  end
end
