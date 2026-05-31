defmodule AllbertBrowser.Actions do
  @moduledoc false

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Security.PermissionGate

  @plugin_id "allbert.browser"

  def capability(permission, attrs \\ %{}) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    %{
      permission: permission,
      exposure: :internal,
      execution_mode: :browser_session,
      skill_backed?: false,
      confirmation: :not_required,
      plugin_id: @plugin_id
    }
    |> Map.merge(attrs)
  end

  def authorize(permission, context), do: PermissionGate.authorize(permission, context)
  def allowed?(decision), do: PermissionGate.allowed?(decision)
  def status_from_decision(decision), do: PermissionGate.response_status(decision)

  def field(map, key, default \\ nil)

  def field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  def field(_map, _key, default), do: default

  def approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  def action(name, status, permission, decision, metadata \\ %{}) do
    %{
      name: name,
      status: status,
      permission: permission,
      permission_decision: decision,
      plugin_id: @plugin_id,
      browser: metadata
    }
  end

  def denied(name, permission, decision, reason) do
    status = if reason == :permission_denied, do: status_from_decision(decision), else: :denied

    {:ok,
     %{
       message: "Browser action #{name} was denied: #{inspect(reason)}.",
       status: status,
       error: reason,
       permission_decision: decision,
       actions: [action(name, status, permission, decision, %{error: reason})]
     }}
  end

  def confirmation(
        name,
        permission,
        execution_mode,
        params_summary,
        resume_params,
        context,
        decision
      ) do
    attrs = %{
      origin: Origin.from_context(context, "browser"),
      target_action: %{name: name},
      target_permission: permission,
      target_execution_mode: execution_mode,
      security_decision: decision,
      params_summary: params_summary,
      resume_params_ref: resume_params
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        id = Map.get(confirmation, "id")

        {:ok,
         %{
           message: "Browser action #{name} requires confirmation #{id}.",
           status: :needs_confirmation,
           permission_decision: decision,
           confirmation: confirmation,
           confirmation_id: id,
           actions: [
             action(name, :needs_confirmation, permission, decision, %{
               confirmation_id: id,
               execution: :pending_confirmation,
               params_summary: params_summary
             })
           ]
         }}

      {:error, reason} ->
        denied(name, permission, decision, reason)
    end
  end
end
