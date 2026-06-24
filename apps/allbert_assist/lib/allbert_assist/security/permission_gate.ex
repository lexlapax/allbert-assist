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
          | :conversation_write
          | :memory_write
          | :command_plan
          | :command_execute
          | :coding_file_read
          | :coding_file_write
          | :coding_shell_execute
          | :external_network
          | :package_install
          | :online_skill_import
          | :settings_write
          | :skill_write
          | :dynamic_codegen_request
          | :dynamic_codegen_discard
          | :skill_script_execute
          | :confirmation_decide
          | :objective_write
          | :workspace_canvas_write
          | :sandbox_trial
          | :dynamic_integration
          | :stocksage_write
          | :stocksage_analyze
          | :stocksage_evidence_fetch
          | :microphone_capture
          | :voice_transcribe
          | :voice_synthesize
          | :voice_local_runtime_manage
          | :image_input
          | :image_generate
          | :artifact_read
          | :artifact_write
          | :artifact_delete
          | :tool_discovery
          | :mcp_server_connect
          | :mcp_tool_call
          | :mcp_resource_read
          | :browser_session_start
          | :browser_navigate
          | :browser_extract
          | :browser_screenshot
          | :browser_interact
          | :browser_form_fill
          | :browser_download
          | :workflow_read
          | :workflow_run_start
          | :plan_cancel
          | :marketplace_install
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

  @doc "Return the Pi-mode approval-mode vocabulary."
  def approval_modes, do: Policy.approval_modes()

  @doc "Read the Pi-mode approval mode from a context map."
  def approval_mode(context), do: Policy.approval_mode(context)

  @doc "Return the Pi-mode coding trust-tier vocabulary."
  def coding_tiers, do: Policy.coding_tiers()

  @doc "Resolve the Pi-mode coding trust tier from explicit context."
  def coding_tier(context), do: Policy.coding_tier(context)

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
