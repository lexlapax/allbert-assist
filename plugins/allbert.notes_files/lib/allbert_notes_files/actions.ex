defmodule AllbertNotesFiles.Actions do
  @moduledoc false

  alias AllbertAssist.Security.PermissionGate

  @app_id :notes_files
  @plugin_id "allbert.notes_files"

  def capability(permission, attrs \\ %{}) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    %{
      permission: permission,
      exposure: :agent,
      execution_mode: :read_only,
      skill_backed?: true,
      confirmation: :not_required,
      app_id: @app_id,
      plugin_id: @plugin_id
    }
    |> Map.merge(attrs)
  end

  def authorize(permission, context), do: PermissionGate.authorize(permission, context)
  def allowed?(decision), do: PermissionGate.allowed?(decision)
  def status_from_decision(decision), do: PermissionGate.response_status(decision)

  def field(map, key, default \\ nil)

  def field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  def field(_map, _key, default), do: default

  def positive_limit(value, _default, max) when is_integer(value) and value > 0 do
    min(value, max)
  end

  def positive_limit(value, default, max) when is_binary(value) do
    value
    |> Integer.parse()
    |> case do
      {integer, ""} -> positive_limit(integer, default, max)
      _other -> default
    end
  end

  def positive_limit(_value, default, _max), do: default

  def action(name, status, permission, decision, metadata \\ %{}) do
    %{
      name: name,
      status: status,
      permission: permission,
      permission_decision: decision,
      app_id: @app_id,
      plugin_id: @plugin_id,
      notes_files: metadata
    }
  end

  def denied(name, permission, decision, reason) do
    status = status_from_decision(decision)

    {:ok,
     %{
       message: "Notes/files action #{name} was denied: #{inspect(reason)}.",
       status: status,
       error: reason,
       permission_decision: decision,
       actions: [action(name, status, permission, decision, %{error: reason})]
     }}
  end
end
