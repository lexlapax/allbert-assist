defmodule AllbertAssist.Actions.Conversations.ResumeThreadOnChannel do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :conversation_write,
    exposure: :agent,
    execution_mode: :conversation_resume,
    skill_backed?: false,
    confirmation: :not_required,
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
      provider_thread_ref: [type: :map, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      resume: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Conversations.UnifiedHistory
  alias AllbertAssist.Security.PermissionGate

  @permission :conversation_write

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(@permission, context)

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
