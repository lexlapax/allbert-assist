defmodule AllbertAssist.TestSupport.ActionEnvelopeAssertions do
  @moduledoc false

  import ExUnit.Assertions

  alias AllbertAssist.Runtime.Response

  @channel_response_keys [
    :actions,
    :diagnostics,
    :doctor,
    :message,
    :permission_decision,
    :status
  ]
  @channel_action_keys [
    :channel_metadata,
    :name,
    :permission,
    :permission_decision,
    :status
  ]
  @canonical_runner_keys [
    :actions,
    :approval_handoff,
    :decision,
    :diagnostics,
    :message,
    :model_payload,
    :permission_decision,
    :resource_access,
    :runner_metadata,
    :status,
    :surface_payload
  ]
  @mcp_callback_denial_keys [
    :actions,
    :error,
    :message,
    :permission_decision,
    :status
  ]

  def assert_channel_envelope(response, expected) do
    assert sorted_keys(response) == @channel_response_keys
    assert response.message == Keyword.fetch!(expected, :message)
    assert response.status == Keyword.fetch!(expected, :status)
    assert response.diagnostics == Keyword.fetch!(expected, :diagnostics)

    assert_permission_decision(
      response.permission_decision,
      :read_only,
      Keyword.fetch!(expected, :decision)
    )

    assert [action] = response.actions
    assert sorted_keys(action) == @channel_action_keys
    assert action.name == Keyword.fetch!(expected, :name)
    assert action.status == Keyword.fetch!(expected, :action_status)
    assert action.permission == :read_only
    assert action.permission_decision == response.permission_decision
    assert action.channel_metadata == Keyword.fetch!(expected, :metadata)

    response
  end

  def assert_mcp_envelope(response, expected) do
    extra_keys = Keyword.get(expected, :extra_keys, [])

    assert sorted_keys(response) == Enum.sort(@canonical_runner_keys ++ extra_keys)
    assert Response.canonical_action_response?(response)
    assert response.message == Keyword.fetch!(expected, :message)
    assert response.model_payload == response.message
    assert response.surface_payload == response.message
    assert response.status == Keyword.fetch!(expected, :status)
    assert response.decision == nil
    assert response.resource_access == []
    assert response.approval_handoff == nil
    assert response.diagnostics == []

    permission = Keyword.fetch!(expected, :permission)
    decision = Keyword.fetch!(expected, :decision)
    assert_permission_decision(response.permission_decision, permission, decision)

    assert [action] = response.actions
    assert action.name == Keyword.fetch!(expected, :name)
    assert action.status == Keyword.fetch!(expected, :action_status)
    assert action.permission == permission
    assert action.permission_decision == response.permission_decision
    assert action.mcp_scan_metadata == Keyword.fetch!(expected, :metadata)
    assert action.runner_metadata == response.runner_metadata

    assert response.runner_metadata.action_name == action.name
    assert response.runner_metadata.status == response.status
    assert response.runner_metadata.permission_decision == response.permission_decision

    response
  end

  def assert_mcp_callback_denial(response, expected) do
    assert sorted_keys(response) == @mcp_callback_denial_keys
    assert response.message == response.permission_decision.reason
    assert response.status == :denied
    assert response.error == :permission_denied

    permission = Keyword.fetch!(expected, :permission)
    assert_permission_decision(response.permission_decision, permission, :denied)

    assert [action] = response.actions

    assert sorted_keys(action) == [
             :mcp_scan_metadata,
             :name,
             :permission,
             :permission_decision,
             :status
           ]

    assert action.name == Keyword.fetch!(expected, :name)
    assert action.status == :denied
    assert action.permission == permission
    assert action.permission_decision == response.permission_decision
    assert action.mcp_scan_metadata == Keyword.fetch!(expected, :metadata)

    response
  end

  defp assert_permission_decision(permission_decision, permission, decision) do
    assert Map.take(permission_decision, [
             :permission,
             :decision,
             :requires_confirmation,
             :source
           ]) == %{
             permission: permission,
             decision: decision,
             requires_confirmation: false,
             source: AllbertAssist.Security
           }
  end

  defp sorted_keys(map), do: map |> Map.keys() |> Enum.sort()
end
