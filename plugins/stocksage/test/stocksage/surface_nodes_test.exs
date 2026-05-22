defmodule StockSage.SurfaceNodesTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Surface.Node
  alias StockSage.SurfaceNodes

  test "completed results build validated StockSage card nodes" do
    analysis = %{
      id: "ana_surface_nodes",
      symbol: "AAPL",
      status: "completed",
      recommendation: "Overweight"
    }

    validated = %{
      ticker: "AAPL",
      analysis_date: ~D[2026-05-15],
      engine: "native",
      objective_id: "obj_surface_nodes",
      step_id: "step_surface_nodes"
    }

    result = %{
      request_id: "native-surface-nodes",
      recommendation: "Overweight",
      confidence: 0.82,
      warnings: ["bounded warning"],
      agent_reports: %{
        "stocksage.market_context" => %{
          role: "analyst",
          status: "completed",
          rating: "Overweight",
          confidence: 0.81,
          summary: "Momentum improved."
        }
      },
      debate_rounds: [
        %{
          round_index: 1,
          bull: %{status: "completed", rating: "Buy", summary: "Bull case."},
          bear: %{status: "completed", rating: "Hold", summary: "Bear case."},
          risks: [%{status: "completed", rating: "Hold", summary: "Risk case."}]
        }
      ]
    }

    assert {:ok, nodes} =
             SurfaceNodes.completed(
               analysis,
               validated,
               result,
               %{trace_id: "trace_surface"},
               "done",
               12,
               false,
               false
             )

    assert Enum.map(nodes, & &1.component) == [
             :analysis_card,
             :agent_report_card,
             :debate_round_card,
             :debate_round_card,
             :debate_round_card
           ]

    assert {:ok, _validated_nodes} = SurfaceNodes.validate_nodes(nodes)
  end

  test "failed results build a validated analysis card node" do
    validated = %{
      ticker: "AAPL",
      analysis_date: ~D[2026-05-15],
      engine: "native",
      objective_id: "obj_failed_surface",
      step_id: "step_failed_surface"
    }

    assert {:ok, [%Node{component: :analysis_card, props: props}]} =
             SurfaceNodes.failed(
               "ana_failed_surface",
               validated,
               %{trace_id: "trace_failed"},
               "provider unavailable",
               9
             )

    assert props.status == "failed"
    assert props.summary == "provider unavailable"
  end

  test "persisted analyses rehydrate card nodes from details" do
    analysis = %{
      id: "ana_persisted_surface",
      symbol: "AAPL",
      status: "completed",
      engine: "native",
      recommendation: "Overweight",
      summary: "Persisted summary.",
      objective_id: "obj_persisted_surface",
      details: [
        %{
          payload: %{
            "native_report" => %{
              "agent_reports" => %{
                "stocksage.market_context" => %{
                  "role" => "analyst",
                  "status" => "completed",
                  "summary" => "Persisted report."
                }
              },
              "debate_rounds" => [
                %{
                  "round_index" => 1,
                  "bull" => %{"status" => "completed", "summary" => "Bull persisted."}
                }
              ]
            }
          }
        }
      ]
    }

    assert {:ok, nodes} = SurfaceNodes.from_analysis(analysis)

    assert Enum.map(nodes, & &1.component) == [
             :analysis_card,
             :agent_report_card,
             :debate_round_card
           ]
  end

  test "rejects components not declared by the StockSage surface catalog" do
    assert {:error,
            [%{kind: :undeclared_surface_component, detail: %{components: [:queue_entry]}}]} =
             SurfaceNodes.validate_nodes([
               %Node{id: "queue-entry", component: :queue_entry, props: %{}}
             ])
  end
end
