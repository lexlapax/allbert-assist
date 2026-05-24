defmodule AllbertAssist.Security.PermissionGate do
  @moduledoc """
  Compatibility permission gate for runtime actions.

  v0.05 keeps this module as the stable action-facing entrypoint while
  delegating decision construction to Security Central.

  v0.31 marks this as a compatibility shim in `AllbertAssist.Boundary`.
  M8 retires it only after direct `AllbertAssist.Security` callers have parity
  tests and security eval coverage.
  """

  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Security
  alias AllbertAssist.Security.Policy

  @type permission ::
          :read_only
          | :memory_write
          | :command_plan
          | :command_execute
          | :external_network
          | :package_install
          | :online_skill_import
          | :settings_write
          | :skill_write
          | :skill_script_execute
          | :confirmation_decide
          | :objective_write
          | :workspace_canvas_write
          | :sandbox_trial
          | :stocksage_write
          | :stocksage_analyze
          | :stocksage_evidence_fetch
          | :settings_secret_write
          | :settings_secret_read

  @type decision :: %{
          permission: permission() | atom(),
          decision: :allowed | :needs_confirmation | :denied,
          reason: String.t(),
          requires_confirmation: boolean(),
          source: module()
        }

  @doc "Return the permission classes recognized by the compatibility gate."
  def permission_classes, do: Policy.permission_classes()

  @doc """
  Authorize a permission class through Security Central.
  """
  @spec authorize(atom(), map()) :: decision()
  def authorize(permission, context \\ %{}) do
    permission
    |> Security.authorize(context)
    |> Map.put(:source, __MODULE__)
  end

  @doc "Map a permission decision to the runtime response status vocabulary."
  @spec response_status(decision()) :: :completed | :needs_confirmation | :denied
  def response_status(decision), do: Response.permission_status(decision)

  @doc "Return true only when the gate allowed the permission."
  @spec allowed?(decision()) :: boolean()
  def allowed?(%{decision: :allowed}), do: true
  def allowed?(_decision), do: false
end
