defmodule AllbertAssist.Actions.Execution.ReleaseCancellationProof do
  @moduledoc """
  Confirmation-gated packaged rehearsal of ADR 0085 cancellation containment.

  The action is internal and absent from intent candidates. Its only parameter
  is a closed proof mode; it does not expose general process execution.
  """

  use AllbertAssist.Action,
    permission: :command_execute,
    exposure: :internal,
    execution_mode: :release_validation,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    retry_safety: :safe,
    name: "release_cancellation_proof",
    description: "Run a bounded packaged cancellation-containment rehearsal.",
    category: "execution",
    tags: ["execution", "cancellation", "release_validation", "internal"],
    schema: [mode: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      proof: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Support.ConfirmationRequest
  alias AllbertAssist.Execution.CancellationProof
  alias AllbertAssist.Maps
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    mode = Maps.field(params, :mode)
    decision = PermissionGate.authorize(:command_execute, context)

    cond do
      mode not in CancellationProof.modes() ->
        response(:error, decision, "Unsupported cancellation proof mode.")

      not PermissionGate.allowed?(decision) and not approval_resume?(context) ->
        request_or_deny(mode, decision, context)

      true ->
        execute(mode, decision)
    end
  end

  defp request_or_deny(mode, decision, context) do
    attrs = %{
      target_action: %{name: name(), module: inspect(__MODULE__)},
      target_permission: :command_execute,
      target_execution_mode: :release_validation,
      params_summary: %{mode: mode},
      resume_params_ref: %{mode: mode}
    }

    case ConfirmationRequest.resolve(decision, attrs, context) do
      {:needs_confirmation, confirmation} ->
        id = confirmation["id"]

        {:ok,
         %{
           message: "Cancellation proof #{mode} is ready for approval. Confirmation: #{id}.",
           status: :needs_confirmation,
           confirmation_id: id,
           confirmation: confirmation,
           permission_decision: decision,
           actions: [action(:needs_confirmation, decision, %{mode: mode, confirmation_id: id})]
         }}

      _denied ->
        response(PermissionGate.response_status(decision), decision, decision.reason)
    end
  end

  defp execute(mode, decision) do
    case proof_runner().(mode) do
      {:ok, proof} ->
        status = if proof.status == :passed, do: :completed, else: :failed

        {:ok,
         %{
           message: render_proof(proof),
           status: status,
           proof: proof,
           output_data: proof,
           permission_decision: decision,
           actions: [action(status, decision, proof)]
         }}

      {:error, reason} ->
        response(:error, decision, "Cancellation proof failed: #{inspect(reason)}")
    end
  end

  defp render_proof(proof) do
    fields =
      proof
      |> Map.put(
        :status,
        if(proof.status == :passed, do: "PASS", else: String.upcase(to_string(proof.status)))
      )
      |> Map.take([
        :status,
        :mode,
        :containment,
        :boundary,
        :timed_out?,
        :target_tree_dead?,
        :sibling_survived?,
        :cleanup_complete?
      ])

    ordered = [
      :status,
      :mode,
      :containment,
      :boundary,
      :timed_out?,
      :target_tree_dead?,
      :sibling_survived?,
      :cleanup_complete?
    ]

    "OV12 " <>
      (ordered
       |> Enum.flat_map(fn key ->
         case Map.fetch(fields, key) do
           {:ok, value} -> ["#{key}=#{value}"]
           :error -> []
         end
       end)
       |> Enum.join(" "))
  end

  defp response(status, decision, message) do
    {:ok,
     %{
       message: message,
       status: status,
       permission_decision: decision,
       actions: [action(status, decision, %{})]
     }}
  end

  defp action(status, decision, metadata) do
    Map.merge(
      %{
        name: name(),
        status: status,
        permission: :command_execute,
        permission_decision: decision
      },
      metadata
    )
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp proof_runner do
    Application.get_env(:allbert_assist, :cancellation_proof_runner, &CancellationProof.run/1)
  end
end
