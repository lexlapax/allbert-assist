defmodule AllbertAssist.Actions.DynamicPlugins.RollbackIntegration do
  @moduledoc """
  Confirmation-backed action for removing live dynamic integration authority.
  """

  use AllbertAssist.Action,
    permission: :dynamic_integration,
    exposure: :internal,
    execution_mode: :dynamic_loader,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "rollback_dynamic_integration",
    description: "Rollback a live dynamic integration and unregister its action overlay entries.",
    category: "dynamic_plugins",
    tags: ["dynamic-plugins", "rollback", "confirmation-required", "internal"],
    schema: [
      slug: [type: :string, required: true],
      revision: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      confirmation: [type: :map, required: false],
      integration: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.Draft
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:dynamic_integration, context)
    slug = Map.get(params, :slug) || Map.get(params, "slug")
    revision = Map.get(params, :revision) || Map.get(params, "revision")

    cond do
      not is_binary(slug) ->
        denied(permission_decision, :invalid_params)

      permission_decision.decision == :denied ->
        denied(permission_decision, :permission_denied)

      approval_resume?(context) ->
        rollback(slug, revision, context, permission_decision)

      true ->
        create_confirmation(slug, revision, context, permission_decision)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:dynamic_integration, context)
    denied(permission_decision, :invalid_params)
  end

  defp rollback(slug, revision, context, permission_decision) do
    case DynamicPlugins.rollback_integration(slug, revision, context: context) do
      {:ok, result} ->
        {:ok,
         %{
           message: "Dynamic integration #{slug} rolled back.",
           status: :completed,
           permission_decision: permission_decision,
           integration: result.integration,
           dynamic_plugin_metadata: result,
           actions: [action(:completed, permission_decision, result)]
         }}

      {:error, reason} ->
        failed(permission_decision, reason)
    end
  end

  defp create_confirmation(slug, revision, context, permission_decision) do
    with {:ok, integration} <- MetadataStore.get_integration(slug, revision),
         {:ok, confirmation} <-
           Confirmations.create(confirmation_attrs(integration, context, permission_decision)),
         {:ok, integration} <- cache_confirmation(integration, confirmation),
         {:ok, _draft} <- cache_draft_confirmation(integration, confirmation) do
      {:ok,
       %{
         message: confirmation_message(integration, permission_decision, confirmation),
         status: :needs_confirmation,
         permission_decision: permission_decision,
         confirmation: confirmation,
         confirmation_id: confirmation_id(confirmation),
         integration: Draft.summary(integration),
         actions: [
           action(:needs_confirmation, permission_decision, %{confirmation: confirmation})
         ]
       }}
    else
      {:error, reason} ->
        failed(permission_decision, reason)
    end
  end

  defp confirmation_attrs(integration, context, permission_decision) do
    %{
      origin: Origin.from_context(context, "rollback_dynamic_integration"),
      target_action: %{name: "rollback_dynamic_integration", module: inspect(__MODULE__)},
      target_permission: :dynamic_integration,
      target_execution_mode: :dynamic_loader,
      security_decision: permission_decision,
      source_signal_id: Map.get(context, :runner_requested_signal_id),
      source_trace_id: Map.get(context, :trace_id),
      runner_metadata: Map.get(context, :runner_metadata, %{}),
      params_summary: %{
        slug: integration.slug,
        revision: integration.revision,
        tier: integration.tier
      },
      resume_params_ref: %{slug: integration.slug, revision: integration.revision}
    }
  end

  defp cache_confirmation(integration, confirmation) do
    integration
    |> Map.update!(:confirmations, &Map.put(&1, "rollback_id", confirmation_id(confirmation)))
    |> MetadataStore.put_integration()
  end

  defp cache_draft_confirmation(integration, confirmation) do
    case MetadataStore.get_draft(integration.slug) do
      {:ok, %Draft{revision: revision} = draft} when revision == integration.revision ->
        draft
        |> Map.update!(:confirmations, &Map.put(&1, "rollback_id", confirmation_id(confirmation)))
        |> MetadataStore.put_draft()

      {:ok, draft} ->
        {:ok, draft}

      {:error, _reason} ->
        {:ok, nil}
    end
  end

  defp confirmation_message(integration, permission_decision, confirmation) do
    """
    Dynamic integration #{integration.slug} revision #{integration.revision} is ready for rollback approval.

    Permission gate decision: #{permission_decision.decision} for dynamic_integration.
    Confirmation request: #{confirmation_id(confirmation)}.
    Live action authority remains active until approval resumes this rollback.
    """
    |> String.trim()
  end

  defp denied(permission_decision, reason) do
    {:ok,
     %{
       message: "Dynamic rollback was denied: #{inspect(reason)}",
       status: :denied,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, %{error: reason})]
     }}
  end

  defp failed(permission_decision, reason) do
    {:ok,
     %{
       message: "Could not rollback dynamic integration: #{inspect(reason)}",
       status: :denied,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, %{error: reason})]
     }}
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "rollback_dynamic_integration",
      status: status,
      permission: :dynamic_integration,
      permission_decision: permission_decision,
      dynamic_plugin_metadata: metadata
    }
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp confirmation_id(%{"id" => id}), do: id
  defp confirmation_id(_confirmation), do: nil
end
