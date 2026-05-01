defmodule AllbertAssist.Security.PermissionGate do
  @moduledoc """
  Central permission decision point for v0.01 actions.

  The gate is intentionally small and explicit. Actions ask for a permission
  class, receive a structured decision, and include that decision in their
  response so operators can inspect why a capability did or did not run.
  """

  @permission_classes [
    :read_only,
    :memory_write,
    :command_plan,
    :command_execute,
    :external_network
  ]

  @type permission ::
          :read_only | :memory_write | :command_plan | :command_execute | :external_network

  @type decision :: %{
          permission: permission() | atom(),
          decision: :allowed | :needs_confirmation | :denied,
          reason: String.t(),
          requires_confirmation: boolean(),
          source: module()
        }

  @doc "Return the permission classes recognized in v0.01."
  @spec permission_classes() :: [permission()]
  def permission_classes, do: @permission_classes

  @doc """
  Authorize a permission class for the current v0.01 runtime.

  M4 only decides. It does not yet present a confirmation UI or persist traces.
  """
  @spec authorize(atom(), map()) :: decision()
  def authorize(permission, context \\ %{})

  def authorize(:read_only, _context) do
    decision(:read_only, :allowed, "Read-only inspection is allowed locally.")
  end

  def authorize(:memory_write, _context) do
    decision(
      :memory_write,
      :allowed,
      "Memory-write intent is allowed, but durable markdown persistence starts in M5."
    )
  end

  def authorize(:command_plan, _context) do
    decision(:command_plan, :allowed, "Planning shell work is allowed when no command executes.")
  end

  def authorize(:command_execute, _context) do
    decision(:command_execute, :denied, "Command execution is not available in v0.01.")
  end

  def authorize(:external_network, _context) do
    decision(
      :external_network,
      :needs_confirmation,
      "External network access requires an explicit future confirmation flow."
    )
  end

  def authorize(permission, _context) do
    decision(permission, :denied, "Unknown permission class: #{inspect(permission)}.")
  end

  @doc "Map a permission decision to the runtime response status vocabulary."
  @spec response_status(decision()) :: :completed | :needs_confirmation | :denied
  def response_status(%{decision: :allowed}), do: :completed
  def response_status(%{decision: :needs_confirmation}), do: :needs_confirmation
  def response_status(%{decision: :denied}), do: :denied

  @doc "Return true only when the gate allowed the permission."
  @spec allowed?(decision()) :: boolean()
  def allowed?(%{decision: :allowed}), do: true
  def allowed?(_decision), do: false

  defp decision(permission, decision, reason) do
    %{
      permission: permission,
      decision: decision,
      reason: reason,
      requires_confirmation: decision == :needs_confirmation,
      source: __MODULE__
    }
  end
end
