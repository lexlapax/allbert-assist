defmodule AllbertAssist.Actions.DynamicPlugins.IntegrateDraft do
  @moduledoc """
  Confirmation-backed action for integrating one gate-passed dynamic draft.
  """

  use AllbertAssist.Action,
    permission: :dynamic_integration,
    exposure: :internal,
    execution_mode: :dynamic_loader,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "integrate_dynamic_draft",
    description: "Integrate a gate-passed dynamic draft into the live runtime overlay.",
    category: "dynamic_plugins",
    tags: ["dynamic-plugins", "loader", "confirmation-required", "internal"],
    schema: [
      slug: [type: :string, required: true]
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

    cond do
      not is_binary(slug) ->
        denied(permission_decision, :invalid_params)

      permission_decision.decision == :denied ->
        denied(permission_decision, :permission_denied)

      approval_resume?(context) ->
        integrate(slug, context, permission_decision)

      true ->
        create_confirmation(slug, context, permission_decision)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:dynamic_integration, context)
    denied(permission_decision, :invalid_params)
  end

  defp integrate(slug, context, permission_decision) do
    case DynamicPlugins.integrate_draft(slug, context: context) do
      {:ok, result} ->
        {:ok,
         %{
           message: "Dynamic draft #{slug} integrated.",
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

  defp create_confirmation(slug, context, permission_decision) do
    with {:ok, draft} <- MetadataStore.get_draft(slug),
         {:ok, confirmation} <-
           Confirmations.create(confirmation_attrs(draft, context, permission_decision)),
         {:ok, draft} <- cache_confirmation(draft, confirmation) do
      {:ok,
       %{
         message: confirmation_message(draft, permission_decision, confirmation),
         status: :needs_confirmation,
         permission_decision: permission_decision,
         confirmation: confirmation,
         confirmation_id: confirmation_id(confirmation),
         draft: Draft.summary(draft),
         actions: [
           action(:needs_confirmation, permission_decision, %{confirmation: confirmation})
         ]
       }}
    else
      {:error, reason} ->
        failed(permission_decision, reason)
    end
  end

  defp confirmation_attrs(draft, context, permission_decision) do
    %{
      origin: Origin.from_context(context, "integrate_dynamic_draft"),
      target_action: %{name: "integrate_dynamic_draft", module: inspect(__MODULE__)},
      target_permission: :dynamic_integration,
      target_execution_mode: :dynamic_loader,
      security_decision: permission_decision,
      source_signal_id: Map.get(context, :runner_requested_signal_id),
      source_trace_id: Map.get(context, :trace_id),
      runner_metadata: Map.get(context, :runner_metadata, %{}),
      params_summary: %{
        slug: draft.slug,
        revision: draft.revision,
        tier: draft.tier,
        gate_status: Map.get(draft.gate, "status"),
        target_shapes: draft.target_shapes
      },
      resume_params_ref: %{slug: draft.slug}
    }
  end

  defp cache_confirmation(draft, confirmation) do
    draft
    |> Map.update!(:confirmations, &Map.put(&1, "integration_id", confirmation_id(confirmation)))
    |> MetadataStore.put_draft()
  end

  defp confirmation_message(draft, permission_decision, confirmation) do
    """
    Dynamic draft #{draft.slug} revision #{draft.revision} is ready for operator approval.

    Permission gate decision: #{permission_decision.decision} for dynamic_integration.
    Confirmation request: #{confirmation_id(confirmation)}.
    Nothing has been loaded into the core node yet.
    """
    |> String.trim()
  end

  defp denied(permission_decision, reason) do
    {:ok,
     %{
       message: "Dynamic integration was denied: #{inspect(reason)}",
       status: :denied,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, %{error: reason})]
     }}
  end

  defp failed(permission_decision, reason) do
    {:ok,
     %{
       message: "Could not integrate dynamic draft: #{inspect(reason)}",
       status: :denied,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, %{error: reason})]
     }}
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "integrate_dynamic_draft",
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
