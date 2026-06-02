defmodule AllbertAssist.Actions.Marketplace.Support do
  @moduledoc false

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Marketplace.Diagnostic
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @spec field(map(), atom(), term()) :: term()
  def field(map, key, default \\ nil)

  def field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  def field(_map, _key, default), do: default

  @spec read_only(String.t(), map(), (map() -> {:ok, map()} | {:error, map()})) :: {:ok, map()}
  def read_only(action_name, context, fun) do
    if marketplace_enabled?() do
      decision = PermissionGate.authorize(:read_only, context)

      if PermissionGate.allowed?(decision) do
        fun.(decision)
      else
        {:ok, denied(action_name, :read_only, decision, :permission_denied)}
      end
    else
      {:ok, disabled(action_name, :read_only)}
    end
  end

  @spec gated_write(String.t(), atom(), map(), map(), (map() -> {:ok, map()} | {:error, map()})) ::
          {:ok, map()}
  def gated_write(action_name, execution_mode, params, context, fun) do
    if marketplace_enabled?() do
      decision = PermissionGate.authorize(:marketplace_install, context)

      cond do
        decision.decision == :denied ->
          {:ok, denied(action_name, :marketplace_install, decision, :permission_denied)}

        decision.decision == :needs_confirmation and not approved_resume?(context) ->
          create_confirmation(action_name, execution_mode, params, context, decision)

        true ->
          fun.(decision)
      end
    else
      {:ok, disabled(action_name, :marketplace_install)}
    end
  end

  @spec marketplace_enabled?() :: boolean()
  def marketplace_enabled? do
    case Settings.get("marketplace.enabled") do
      {:ok, false} -> false
      _other -> true
    end
  end

  @spec disabled(String.t(), atom()) :: map()
  def disabled(action_name, permission) do
    diagnostic =
      Diagnostic.new(
        :marketplace_disabled,
        :marketplace_disabled,
        "Marketplace Lite is disabled by marketplace.enabled.",
        pointer: "/marketplace/enabled"
      )

    %{
      message: diagnostic.message,
      status: :unavailable,
      permission_decision: %{decision: :denied, reason: :marketplace_disabled},
      error: diagnostic,
      diagnostics: [diagnostic],
      actions: [action(action_name, :unavailable, permission, %{decision: :denied}, diagnostic)]
    }
  end

  @spec completed(String.t(), atom(), map(), map(), String.t()) :: {:ok, map()}
  def completed(action_name, permission, decision, result, message) do
    {:ok,
     %{
       message: message,
       status: :completed,
       permission_decision: decision,
       result: result,
       actions: [action(action_name, :completed, permission, decision, result)]
     }}
  end

  @spec failed(String.t(), atom(), map(), map()) :: {:ok, map()}
  def failed(action_name, permission, decision, diagnostic) do
    {:ok,
     %{
       message: diagnostic.message,
       status: :failed,
       permission_decision: decision,
       error: diagnostic,
       diagnostics: [diagnostic],
       actions: [action(action_name, :failed, permission, decision, %{error: diagnostic})]
     }}
  end

  defp denied(action_name, permission, decision, reason) do
    %{
      message: "Marketplace action denied: #{inspect(reason)}.",
      status: PermissionGate.response_status(decision),
      permission_decision: decision,
      error: reason,
      actions: [action(action_name, :denied, permission, decision, %{error: reason})]
    }
  end

  defp create_confirmation(action_name, execution_mode, params, context, decision) do
    attrs = %{
      origin: Origin.from_context(context, "marketplace"),
      target_action: %{name: action_name},
      target_permission: :marketplace_install,
      target_execution_mode: execution_mode,
      security_decision: decision,
      params_summary: params,
      resume_params_ref: params
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message:
             "Marketplace action is ready for approval. Confirmation request: #{confirmation["id"]}. Nothing has been written yet.",
           status: :needs_confirmation,
           permission_decision: decision,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             %{
               name: action_name,
               status: :needs_confirmation,
               permission: :marketplace_install,
               permission_decision: decision,
               execution: :pending_confirmation,
               confirmation_id: confirmation["id"],
               marketplace_request: params
             }
           ]
         }}

      {:error, reason} ->
        {:ok, denied(action_name, :marketplace_install, decision, reason)}
    end
  end

  defp approved_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp action(action_name, status, permission, decision, metadata) do
    %{
      name: action_name,
      status: status,
      permission: permission,
      permission_decision: decision,
      marketplace_metadata: metadata
    }
  end
end
