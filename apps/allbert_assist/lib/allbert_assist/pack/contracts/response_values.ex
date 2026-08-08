defmodule AllbertAssist.Pack.Contracts.ResponseValues do
  @moduledoc """
  Residual provider for the kernel `ResponseValues` contract.

  Every function here is the exact expression the canonical `Response` used to
  inline. `decision_resource_access_maps/1` and `decision_approval_handoff_map/1`
  read struct fields directly rather than going through `Decision.to_map/1`,
  because `to_map/1` already converts nested resource access and drops empty
  values — routing through it would double-convert and change the rendered
  envelope.
  """

  @behaviour AllbertAssist.Kernel.Contract.ResponseValues

  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Intent.ResourceAccess

  @impl true
  def decision?(%Decision{}), do: true
  def decision?(_term), do: false

  @impl true
  defdelegate decision_to_map(decision), to: Decision, as: :to_map

  @impl true
  def decision_diagnostics(%Decision{diagnostics: diagnostics}), do: diagnostics
  def decision_diagnostics(_decision), do: []

  @impl true
  def decision_resource_access_maps(%Decision{resource_access: entries}),
    do: ResourceAccess.to_maps(entries)

  def decision_resource_access_maps(_decision), do: []

  @impl true
  def decision_approval_handoff_map(%Decision{approval_handoff: handoff}),
    do: ApprovalHandoff.to_map(handoff)

  def decision_approval_handoff_map(_decision), do: nil

  @impl true
  defdelegate resource_access_to_maps(entries), to: ResourceAccess, as: :to_maps

  @impl true
  defdelegate approval_handoff_to_map(handoff), to: ApprovalHandoff, as: :to_map
end
