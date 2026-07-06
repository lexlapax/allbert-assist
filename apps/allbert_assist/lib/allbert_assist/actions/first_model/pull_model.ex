defmodule AllbertAssist.Actions.FirstModel.PullModel do
  @moduledoc """
  Pull the curated default model (v0.62 M4, ADR 0078; M4 Authority Contract).

  Uses the local Ollama REST API (`POST /api/pull`) under the existing
  **`:external_network`** authority — its `:needs_confirmation` safety floor
  means the pull runs only behind a durable operator confirmation. The API path
  is loopback-only and returns a bounded JSON summary; there is no silent
  egress. The trace records the model tag and outcome.
  """

  use AllbertAssist.Action,
    permission: :external_network,
    exposure: :internal,
    execution_mode: :first_model_pull,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "pull_model",
    description: "Pull the curated default model via the local Ollama API (confirmation-gated).",
    category: "first_model",
    tags: ["first_model", "pull", "external_network", "confirmation"],
    schema: [
      model: [type: :string, required: false],
      dry_run: [type: :boolean, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Support.ConfirmationRequest
  alias AllbertAssist.FirstModel.Ollama
  alias AllbertAssist.Security.PermissionGate

  @req_options_key :first_model_req_options

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:external_network, context)
    model = Map.get(params, :model) || Ollama.curated_model()

    cond do
      # dry_run is a pre-gate PREVIEW: no egress, just names the model + local
      # endpoint. Real pull is gated below.
      Map.get(params, :dry_run, false) ->
        {:ok,
         %{
           message: "Would pull #{model} via #{Ollama.base_url()}/api/pull",
           status: :completed,
           permission_decision: permission_decision,
           actions: [action(:completed, permission_decision, %{model: model, executed: false})]
         }}

      not PermissionGate.allowed?(permission_decision) and not approval_resume?(context) ->
        request_or_deny(permission_decision, model, context)

      true ->
        pull(model, permission_decision)
    end
  end

  # M8.14: persist a durable confirmation so `admin confirmations approve <id>`
  # completes the pull (resumed with the same `model`).
  defp request_or_deny(permission_decision, model, context) do
    attrs = %{
      target_action: %{name: name(), module: inspect(__MODULE__)},
      target_permission: :external_network,
      target_execution_mode: :first_model_pull,
      params_summary: %{model: model, endpoint: "#{Ollama.base_url()}/api/pull"},
      resume_params_ref: %{model: model}
    }

    case ConfirmationRequest.resolve(permission_decision, attrs, context) do
      {:needs_confirmation, confirmation} ->
        {:ok,
         %{
           message:
             "Model pull is ready for approval. Confirmation request: #{confirmation["id"]}. Nothing was pulled.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             action(:needs_confirmation, permission_decision, %{
               model: model,
               executed: false,
               confirmation_id: confirmation["id"]
             })
           ]
         }}

      _denied ->
        denied(permission_decision, model)
    end
  end

  defp pull(model, permission_decision) do
    case do_pull(model) do
      {:ok, summary} ->
        {:ok,
         %{
           message: "Pulled #{model}.",
           status: :completed,
           permission_decision: permission_decision,
           actions: [
             action(:completed, permission_decision, %{
               model: model,
               executed: true,
               summary: summary
             })
           ]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "Pull of #{model} failed: #{inspect(reason)}",
           status: :error,
           permission_decision: permission_decision,
           actions: [action(:error, permission_decision, %{model: model, error: inspect(reason)})]
         }}
    end
  end

  # Injectable puller for tests; default uses POST /api/pull with stream=false.
  defp do_pull(model) do
    puller = Application.get_env(:allbert_assist, :first_model_pull, &default_pull/1)
    puller.(model)
  end

  defp default_pull(model) do
    with {:ok, url} <- Ollama.local_url("/api/pull") do
      opts =
        [
          method: :post,
          url: url,
          json: %{name: model, stream: false},
          receive_timeout: 600_000,
          retry: false,
          redirect: false
        ]
        |> Keyword.merge(Application.get_env(:allbert_assist, @req_options_key, []))

      case Req.request(opts) do
        {:ok, %{status: 200, body: resp}} -> {:ok, summarize(resp)}
        {:ok, %{status: code}} -> {:error, {:http, code}}
        {:error, %Req.TransportError{} = error} -> {:error, error.reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp summarize(resp) when is_map(resp) do
    case resp do
      %{"status" => status} -> %{status: status}
      %{status: status} -> %{status: status}
      _other -> %{status: "completed"}
    end
  end

  defp summarize(resp) do
    case Jason.decode(resp) do
      {:ok, %{"status" => status}} -> %{status: status}
      _other -> %{status: "completed"}
    end
  end

  defp denied(permission_decision, model) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, %{model: model, executed: false})]
     }}
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp action(status, permission_decision, metadata) do
    Map.merge(
      %{
        name: name(),
        status: status,
        permission: :external_network,
        permission_decision: permission_decision
      },
      metadata
    )
  end
end
