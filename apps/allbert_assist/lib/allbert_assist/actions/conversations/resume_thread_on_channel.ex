defmodule AllbertAssist.Actions.Conversations.ResumeThreadOnChannel do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :conversation_write,
    exposure: :agent,
    execution_mode: :conversation_resume,
    skill_backed?: false,
    confirmation: :not_required,
    resumable?: true,
    name: "resume_thread_on_channel",
    description: "Resume a canonical Allbert conversation thread on an explicit channel target.",
    category: "conversations",
    tags: ["conversations", "channels", "threads"],
    schema: [
      thread_id: [type: :string, required: true],
      user_id: [type: :string, required: true],
      channel: [type: :string, required: true],
      receiver_account_ref: [type: :string, required: false],
      external_user_id: [type: :string, required: false],
      provider_thread_key: [type: :string, required: false],
      provider_thread_ref: [type: :map, required: false],
      confirmed_trust_downgrade?: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      resume: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Conversations.UnifiedHistory
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Security.PermissionGate

  @permission :conversation_write

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(@permission, context)
    params = maybe_mark_confirmed(params, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, resume} <- UnifiedHistory.resume_thread_on_channel(params) do
      {:ok,
       %{
         message: message(resume),
         status: :completed,
         resume: resume,
         actions: [action(:completed, permission_decision, resume)]
       }}
    else
      false ->
        denied(params, permission_decision, :permission_denied)

      {:error, {:trust_downgrade_requires_confirmation, downgrade}} ->
        create_trust_downgrade_confirmation(params, context, permission_decision, downgrade)

      {:error, reason} ->
        denied(params, permission_decision, reason)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)
    denied(%{}, permission_decision, :invalid_params)
  end

  defp message(resume) do
    "Resumed thread #{resume.thread_id} for #{resume.user_id} on #{resume.channel} using #{resume.continuity.mode}."
  end

  defp denied(params, permission_decision, reason) do
    {:ok,
     %{
       message: "I could not resume the thread on channel: #{inspect(reason)}",
       status: :denied,
       error: reason,
       actions: [action(:denied, permission_decision, Map.put(params, :error, reason))]
     }}
  end

  defp create_trust_downgrade_confirmation(params, context, permission_decision, downgrade) do
    confirmation_decision = trust_downgrade_decision(permission_decision, downgrade)

    resume_params =
      params
      |> Map.new()
      |> Map.put(:confirmed_trust_downgrade?, true)

    case Confirmations.create(%{
           origin: Origin.from_context(context, "resume_thread_on_channel"),
           target_action: %{name: "resume_thread_on_channel", module: inspect(__MODULE__)},
           target_permission: @permission,
           target_execution_mode: :conversation_resume,
           security_decision: confirmation_decision,
           params_summary: downgrade,
           resume_params_ref: resume_params
         }) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message:
             "Resuming this thread would expose E2EE-origin content on #{downgrade.target_channel}. Confirmation request: #{confirmation["id"]}.",
           status: :needs_confirmation,
           permission_decision: confirmation_decision,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             %{
               name: "resume_thread_on_channel",
               status: :needs_confirmation,
               permission: @permission,
               permission_decision: confirmation_decision,
               execution: :pending_confirmation,
               confirmation_id: confirmation["id"],
               trust_downgrade: downgrade
             }
           ]
         }}

      {:error, reason} ->
        denied(params, permission_decision, reason)
    end
  end

  defp trust_downgrade_decision(permission_decision, downgrade) do
    permission_decision
    |> Map.put(:decision, :needs_confirmation)
    |> Map.put(:requires_confirmation, true)
    |> Map.put(
      :reason,
      "Resuming E2EE-origin content from #{Enum.join(downgrade.source_channels, ", ")} onto #{downgrade.target_channel} requires operator confirmation."
    )
  end

  defp maybe_mark_confirmed(params, context) do
    if get_in(context, [:confirmation, :approved?]) do
      Map.put(params, :confirmed_trust_downgrade?, true)
    else
      params
    end
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "resume_thread_on_channel",
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      channel_metadata: metadata
    }
  end
end
