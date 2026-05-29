defmodule StockSage.Security.StockSageMarketDataEvalTest do
  use StockSage.DataCase, async: false, lane: :security_eval_serial

  import AllbertAssist.SecurityEvalCase

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Resources.Grants
  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "stocksage-v028-market-data-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    PluginRegistry.register_module(StockSage.Plugin)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "market-data-grant-001: generic external grant does not authorize market data" do
    fixture = EvalInventory.row!("market-data-grant-001")

    [generic_ref] =
      Ref.from_external_request_summary(%{
        url: "https://example.com/status",
        canonical_url: "https://example.com/status",
        host: "example.com",
        path: "/status"
      })

    assert {:ok, generic_grant} =
             Grants.remember(generic_ref,
               id: "grant-generic-external-request",
               reason: "operator remembered a generic API request",
               audit?: false
             )

    eval =
      run_eval(
        Map.merge(fixture, %{
          run: fn fixture ->
            {:ok, response} =
              Runner.run(
                "stocksage_fetch_market_data",
                %{ticker: "AAPL", analysis_date: "2026-05-22", evidence_mode: "live"},
                %{
                  active_app: :stocksage,
                  actor: "alice",
                  user_id: "alice",
                  channel: :test,
                  resource_grants: [generic_grant],
                  request: %{active_app: :stocksage, operator_id: "alice", channel: :test}
                }
              )

            %{
              decision: response.status,
              result: response,
              trace: %{
                fixture_id: fixture.id,
                boundary: :resource_access,
                remembered_grant_operation: generic_grant["operation_class"],
                remembered_grant_consumer: generic_grant["downstream_consumer"],
                requested_consumer: hd(response.resource_access).downstream_consumer,
                resource_decision: get_in(response.actions, [Access.at(0), :permission_decision])
              },
              transport_calls: %{external_network: 0}
            }
          end
        })
      )

    assert_needs_confirmation(eval)
    assert_trace_records(eval, [:resource_decision, :requested_consumer])
    assert_fixture_transport_calls(eval, :external_network, 0)
    assert eval.trace.remembered_grant_consumer == "req_http"
    assert eval.trace.requested_consumer == "stocksage_fetch_market_data"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
