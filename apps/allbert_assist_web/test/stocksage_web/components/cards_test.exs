defmodule StockSageWeb.Components.CardsTest do
  use AllbertAssistWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias AllbertAssist.Surface.Node
  alias StockSageWeb.Components.SurfaceRenderer

  test "renders all StockSage card atoms without the v0.26 stub marker" do
    for {component, props, expected} <- card_cases() do
      assigns = %{
        node: %Node{
          id: "node-#{component}",
          component: component,
          props: props
        }
      }

      html = rendered_to_string(~H"<SurfaceRenderer.node node={@node} />")

      assert html =~ ~s(data-stocksage-component="#{component}")
      assert html =~ expected
      refute html =~ "v0.26 stub"
      refute html =~ "component not implemented"
    end
  end

  test "escapes model/provider supplied text" do
    assigns = %{
      node: %Node{
        id: "unsafe-analysis",
        component: :analysis_card,
        props: %{
          ticker: "AAPL",
          summary: "<script>alert('x')</script>",
          status: "completed"
        }
      }
    }

    html = rendered_to_string(~H"<SurfaceRenderer.node node={@node} />")

    assert html =~ "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"
    refute html =~ "<script>"
  end

  test "unsupported StockSage nodes render a bounded fallback" do
    assigns = %{node: %Node{id: "unknown", component: :invented_card, props: %{}}}

    html = rendered_to_string(~H"<SurfaceRenderer.node node={@node} />")

    assert html =~ ~s(data-stocksage-component="unsupported")
    assert html =~ "invented_card"
  end

  defp card_cases do
    [
      {:analysis_card,
       %{
         ticker: "AAPL",
         engine: "native",
         rating: "Overweight",
         confidence: 0.82,
         status: "completed",
         summary: "Constructive setup.",
         analysis_id: "ana_1"
       }, "AAPL"},
      {:agent_report_card,
       %{
         agent: "market_context",
         role: "analyst",
         rating: "Hold",
         confidence: 0.7,
         summary: "Market context is mixed.",
         key_points: ["Momentum improving"]
       }, "market_context"},
      {:parity_card,
       %{
         native_rating: "Overweight",
         python_rating: "Overweight",
         rating_agreement: "exact",
         confidence_delta: 0.04,
         parity_pass: true,
         summary: "Native and Python agree."
       }, "exact"},
      {:debate_round_card,
       %{
         round: 1,
         side: "bull",
         agent: "bull_thesis",
         rating: "Buy",
         summary: "Bull case leads.",
         counterpoints: ["Valuation risk"]
       }, "bull_thesis"}
    ]
  end
end
