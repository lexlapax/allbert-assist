defmodule AllbertAssist.Actions.DynamicPlugins.RunDraftTrial do
  @moduledoc """
  Internal action for running v0.37 draft trial evidence through v0.36 sandbox.
  """

  use AllbertAssist.Action,
    permission: :sandbox_trial,
    exposure: :internal,
    execution_mode: :sandbox_trial,
    skill_backed?: false,
    confirmation: :not_required,
    name: "run_dynamic_draft_trial",
    description: "Run compile and focused-test sandbox evidence for a dynamic draft.",
    category: "dynamic_plugins",
    tags: ["dynamic-plugins", "sandbox", "trial", "internal"],
    schema: [
      slug: [type: :string, required: true],
      profiles: [type: {:list, :atom}, required: false],
      project_root: [type: :string, required: false],
      project_paths: [type: {:list, :string}, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      draft: [type: :map, required: false],
      report: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:sandbox_trial, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, result} <-
           DynamicPlugins.run_draft_trial(params.slug, bridge_opts(params, context)) do
      {:ok, completed(permission_decision, result)}
    else
      false ->
        {:ok, denied(permission_decision)}

      {:error, reason} ->
        {:ok, failed(permission_decision, reason)}
    end
  end

  defp bridge_opts(params, context) do
    params
    |> Map.take([:profiles, :project_root, :project_paths])
    |> Map.put(:operator_id, operator_id(context))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp operator_id(context) do
    Map.get(context, :operator_id) || Map.get(context, "operator_id") ||
      Map.get(context, :user_id) || Map.get(context, "user_id") ||
      Map.get(context, :actor) || Map.get(context, "actor")
  end

  defp completed(permission_decision, result) do
    %{
      message: "Dynamic draft trial finished with status #{result.status}.",
      status: result.status,
      permission_decision: permission_decision,
      draft: result.draft,
      report: result.report,
      actions: [action(result.status, permission_decision, result)]
    }
  end

  defp denied(permission_decision) do
    %{
      message: "Dynamic draft trial is denied by Security Central.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{})]
    }
  end

  defp failed(permission_decision, reason) do
    %{
      message: "Could not run dynamic draft trial: #{inspect(reason)}",
      status: :denied,
      permission_decision: permission_decision,
      error: reason,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "run_dynamic_draft_trial",
      status: status,
      permission: :sandbox_trial,
      permission_decision: permission_decision,
      dynamic_plugin_metadata: metadata
    }
  end
end
