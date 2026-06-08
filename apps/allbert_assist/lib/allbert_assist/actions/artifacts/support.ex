defmodule AllbertAssist.Actions.Artifacts.Support do
  @moduledoc false

  alias AllbertAssist.Runtime.Redactor

  def value(params, key, default \\ nil) when is_map(params) do
    Map.get(params, key, Map.get(params, Atom.to_string(key), default))
  end

  def artifact_ref(params) do
    value(params, :artifact_uri) || value(params, :sha256)
  end

  def approved_resume?(%{confirmation: %{approved?: true}}), do: true
  def approved_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  def approved_resume?(_context), do: false

  def action(name, status, permission, permission_decision, artifact_metadata \\ %{}) do
    %{
      name: name,
      status: status,
      permission: permission,
      permission_decision: permission_decision,
      artifact_metadata: Redactor.redact_artifact_metadata(artifact_metadata)
    }
  end

  def context_value(context, key, default \\ nil) when is_map(context) do
    request = value(context, :request, %{}) || %{}
    value(context, key) || value(request, key) || default
  end
end
