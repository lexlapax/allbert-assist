defmodule AllbertAssist.Intent.ApprovalHandoffTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope

  test "builds pending handoff data from a decision and confirmation result" do
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
                   downstream_consumer: :req_http,
                   allowed_approval_scopes: [:once, :exact_resource, :url_prefix]
                 }
               ],
               context: %{request: %{operator_id: "alice", channel: :test}}
             })

    handoff =
      ApprovalHandoff.pending(
        decision,
        %{
          status: :needs_confirmation,
          confirmation_id: "conf-1",
          confirmation: %{
            "id" => "conf-1",
            "status" => "pending",
            "origin" => %{"channel" => "test"},
            "target_action" => %{"name" => "external_network_request"}
          }
        },
        %{request: %{operator_id: "alice", channel: :test}}
      )

    assert handoff.confirmation_id == "conf-1"
    assert handoff.status == :pending
    assert handoff.origin == %{"channel" => "test"}
    assert [%{operation_class: :external_service_request}] = handoff.resource_access
    assert :approve in handoff.allowed_actions
    assert :deny in handoff.allowed_actions
    assert %{remember: :exact_resource} in handoff.allowed_actions
    assert handoff.render_hints.target_label == "external_network_request"
    assert handoff.result_return.same_channel? == true
  end
end
