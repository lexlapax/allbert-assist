defmodule AllbertAssist.Intent.DecisionTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope

  test "copies action capability and security posture from registered boundaries" do
    assert {:ok, decision} =
             Decision.new(%{
               intent: :external_network_request,
               selected_action: "external_network_request",
               resource_access: [
                 %{
                   resource_uri: ResourceURI.url!("https://example.com/report"),
                   operation_class: :external_service_request,
                   access_mode: :fetch,
                   scope: Scope.exact_url("https://example.com/report"),
                   downstream_consumer: :req_http
                 }
               ],
               context: %{request: %{operator_id: "alice", channel: :test}}
             })

    assert decision.selected_action == "external_network_request"
    assert decision.permission == :external_network
    assert decision.execution_mode == :req_http
    assert decision.confirmation == :required
    assert decision.user_id == "alice"
    assert [%{name: "external_network_request", registered?: true}] = decision.candidate_actions

    assert [%{operation_class: :external_service_request}] =
             Decision.to_map(decision).resource_access

    assert decision.trace_metadata.security_decision.decision == :needs_confirmation
  end

  test "keeps operator_id as the user_id fallback" do
    assert {:ok, decision} =
             Decision.new(%{
               intent: :direct_answer,
               selected_action: "direct_answer",
               context: %{request: %{operator_id: "legacy-operator", channel: :test}}
             })

    assert decision.user_id == "legacy-operator"
    refute Map.has_key?(decision.trace_metadata, :active_app)
  end

  test "preserves context active app and rejects unknown active app output" do
    ensure_stocksage_app!()

    assert {:ok, decision} =
             Decision.new(%{
               intent: :direct_answer,
               selected_action: "direct_answer",
               context: %{
                 request: %{
                   user_id: "alice",
                   session_id: "sess-1",
                   active_app: :stocksage
                 }
               }
             })

    assert decision.active_app == :stocksage
    assert decision.trace_metadata.active_app == :stocksage

    assert {:ok, fallback_decision} =
             Decision.new(%{
               intent: :direct_answer,
               selected_action: "direct_answer",
               active_app: :invented_app,
               context: %{request: %{user_id: "alice", active_app: :stocksage}}
             })

    assert fallback_decision.active_app == :stocksage
    assert [%{kind: :unknown_active_app}] = fallback_decision.diagnostics

    assert {:ok, nil_decision} =
             Decision.new(%{
               intent: :direct_answer,
               selected_action: "direct_answer",
               active_app: :invented_app,
               context: %{request: %{user_id: "alice"}}
             })

    assert nil_decision.active_app == nil
    assert [%{kind: :unknown_active_app}] = nil_decision.diagnostics
  end

  test "rejects unknown actions before they can be invoked" do
    assert {:error, {:unknown_action, "invented_action"}} =
             Decision.new(%{
               intent: :invented,
               selected_action: "invented_action",
               context: %{request: %{operator_id: "local"}}
             })
  end

  test "rejects invalid resource operation classes" do
    assert {:error, {:invalid_resource_access, {:unknown_operation_class, :crawl_everything}}} =
             Decision.new(%{
               intent: :bad_resource,
               selected_action: "direct_answer",
               resource_access: [
                 %{
                   resource_uri: ResourceURI.url!("https://example.com"),
                   operation_class: :crawl_everything,
                   access_mode: :fetch,
                   scope: Scope.exact_url("https://example.com")
                 }
               ],
               context: %{request: %{operator_id: "local"}}
             })
  end

  defp ensure_stocksage_app! do
    registered? = AppRegistry.known_app_id?(:stocksage)

    unless registered? do
      # Tolerate a concurrent/serial-neighbour registration: an earlier test's
      # on_exit unregister may not have completed when this setup runs, so the app
      # can already be registered. Accept that rather than failing the assert.
      assert AppRegistry.register(StockSage.App) in [
               {:ok, :stocksage},
               {:error, {:app_id_taken, :stocksage}}
             ]
    end

    on_exit(fn ->
      unless registered?, do: AppRegistry.unregister(:stocksage)
    end)
  end
end
