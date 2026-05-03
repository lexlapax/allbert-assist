defmodule AllbertAssist.Actions.Intent.ExternalNetworkRequest do
  @moduledoc """
  Handles confirmed external HTTP/service requests through the v0.10 Req adapter.

  Request creation validates and records a durable confirmation without making
  a network call. The target request runs only when approve_confirmation resumes
  this action with an approved confirmation context.
  """

  use Jido.Action,
    name: "external_network_request",
    description: "Create or resume a confirmed external HTTP/service request.",
    category: "intent",
    tags: ["intent", "network", "external_network", "confirmation_required"],
    schema: [
      request: [type: :string, required: false, doc: "The requested network task or URL."],
      url: [type: :string, required: false, doc: "Absolute HTTP(S) URL."],
      profile: [type: :string, required: false, doc: "External service profile name."],
      method: [type: :string, required: false, doc: "HTTP method, default GET."],
      path: [type: :string, required: false, doc: "Profile-relative path."],
      query: [type: :map, required: false, doc: "Optional query parameters."],
      headers: [type: :map, required: false, doc: "Optional request headers."],
      body: [type: :string, required: false, doc: "Optional raw request body."],
      json: [type: :map, required: false, doc: "Optional JSON request body."],
      timeout_ms: [type: :integer, required: false, doc: "Requested timeout."],
      max_response_bytes: [type: :integer, required: false, doc: "Requested response cap."],
      source_text: [type: :string, required: false, doc: "The original user prompt."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.External.Audit
  alias AllbertAssist.External.HttpClient
  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Resources.GrantHandoff
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) when is_map(params) do
    case RequestSpec.normalize(params, context: context) do
      {:ok, spec} ->
        run_spec(spec, context)

      {:error, spec} ->
        denied_response(spec, spec_denial_decision(spec.denial_reason), spec.denial_reason)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:external_network, context)

    {:ok,
     %{
       message: "External network request was denied: invalid request parameters.",
       status: :denied,
       permission_decision: permission_decision,
       request: nil,
       actions: [
         %{
           name: "external_network_request",
           status: :denied,
           permission: :external_network,
           permission_decision: permission_decision,
           execution: :not_started,
           denial_reason: :invalid_params
         }
       ]
     }}
  end

  defp run_spec(spec, context) do
    permission_decision =
      PermissionGate.authorize(:external_network, request_context(spec, context))

    cond do
      permission_decision.decision == :denied ->
        denied_response(spec, permission_decision, spec.denial_reason || :permission_denied)

      approval_resume?(context) ->
        execute_spec(spec, permission_decision, context)

      grant_context =
          grant_execution_context(RequestSpec.summary(spec), :external_network, context) ->
        execute_spec(spec, permission_decision, grant_context)

      true ->
        create_confirmation(spec, context, permission_decision)
    end
  end

  defp denied_response(spec, permission_decision, reason) do
    _audit = Audit.append(:denied, spec, permission_decision, %{denial_reason: reason})

    {:ok,
     %{
       message: "External network request was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       request: RequestSpec.summary(spec),
       actions: [
         %{
           name: "external_network_request",
           status: :denied,
           permission: :external_network,
           permission_decision: permission_decision,
           execution: :not_started,
           request: RequestSpec.summary(spec),
           denial_reason: reason
         }
       ]
     }}
  end

  defp spec_denial_decision(reason) do
    %{
      permission: :external_network,
      decision: :denied,
      reason: "External request policy denied before confirmation: #{inspect(reason)}",
      requires_confirmation: false,
      source: PermissionGate
    }
  end

  defp create_confirmation(spec, context, permission_decision) do
    attrs = %{
      origin: origin(context),
      target_action: %{name: "external_network_request", module: inspect(__MODULE__)},
      target_permission: :external_network,
      target_execution_mode: :req_http,
      selected_skill: selected_skill(context),
      capability_contract: capability_contract(context),
      security_decision: permission_decision,
      source_signal_id: source_signal_id(context),
      source_trace_id: source_trace_id(context),
      runner_metadata: runner_metadata(context),
      params_summary: RequestSpec.summary(spec),
      resume_params_ref: RequestSpec.resume_params(spec)
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        _audit =
          Audit.append(:requested, spec, permission_decision, %{
            confirmation_id: confirmation_id(confirmation)
          })

        {:ok,
         %{
           message: confirmation_message(spec, permission_decision, confirmation),
           status: :needs_confirmation,
           permission_decision: permission_decision,
           request: RequestSpec.summary(spec),
           confirmation: confirmation,
           confirmation_id: confirmation_id(confirmation),
           actions: [
             %{
               name: "external_network_request",
               status: :needs_confirmation,
               permission: :external_network,
               permission_decision: permission_decision,
               execution: :pending_confirmation,
               request: RequestSpec.summary(spec),
               confirmation_id: confirmation_id(confirmation),
               confirmation_metadata: confirmation_metadata(confirmation)
             }
           ]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "Could not create confirmation request for external network request.",
           status: :error,
           error: reason,
           permission_decision: permission_decision,
           request: RequestSpec.summary(spec),
           actions: [
             %{
               name: "external_network_request",
               status: :error,
               permission: :external_network,
               permission_decision: permission_decision,
               execution: :not_started,
               request: RequestSpec.summary(spec),
               error: reason
             }
           ]
         }}
    end
  end

  defp execute_spec(spec, permission_decision, context) do
    confirmation_id = get_in(context, [:confirmation, :id])

    with {:ok, result} <- HttpClient.request(spec, req_opts(context)) do
      _approved_audit =
        Audit.append(
          :approved,
          spec,
          permission_decision,
          Map.merge(%{confirmation_id: confirmation_id}, audit_grant_attrs(context))
        )

      _result_audit =
        Audit.append(result_event(result), spec, permission_decision, %{
          confirmation_id: confirmation_id,
          grant_ids: grant_ids(context),
          result: result
        })

      {:ok,
       %{
         message: execution_message(result),
         status: result.status,
         permission_decision: permission_decision,
         request: RequestSpec.summary(spec),
         result: result,
         actions: [
           %{
             name: "external_network_request",
             status: result.status,
             permission: :external_network,
             permission_decision: permission_decision,
             execution: :req_http,
             request: RequestSpec.summary(spec),
             result: result
           }
           |> Map.put(:target_resumed?, GrantHandoff.target_resumed?(context))
           |> Map.merge(GrantHandoff.action_metadata(context))
         ]
       }}
    end
  end

  defp grant_execution_context(summary, permission, context) do
    case GrantHandoff.find_applicable(Map.get(summary, :resource_refs, []), permission, context) do
      {:ok, grants} -> GrantHandoff.put_applied(context, grants)
      _other -> nil
    end
  end

  defp request_context(spec, context) do
    Map.merge(context, %{
      resource: %{
        kind: :external_http,
        host: spec.host,
        path: spec.path,
        request: RequestSpec.summary(spec)
      }
    })
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp confirmation_message(spec, permission_decision, confirmation) do
    """
    External network request is ready for operator approval.

    Request: #{spec.method} #{RequestSpec.redacted_url(spec)}
    Profile: #{spec.profile}
    Permission gate decision: #{permission_decision.decision} for external_network.
    Confirmation request: #{confirmation_id(confirmation) || "not created"}.
    Nothing has executed yet.
    """
    |> String.trim()
  end

  defp execution_message(%{status: :completed, http_status: status}) do
    "External network request completed with HTTP status #{status}."
  end

  defp execution_message(%{status: :failed, http_status: nil, transport_error: error}) do
    "External network request ran but failed before an HTTP response: #{error}."
  end

  defp execution_message(%{status: :failed, http_status: status}) do
    "External network request ran and returned HTTP status #{status}."
  end

  defp result_event(%{status: :completed}), do: :succeeded
  defp result_event(_result), do: :failed

  defp req_opts(context), do: [plug: req_plug(context)] |> Enum.reject(&is_nil(elem(&1, 1)))

  defp req_plug(context) do
    get_in(context, [:external, :req_plug]) ||
      get_in(context, ["external", "req_plug"]) ||
      Application.get_env(:allbert_assist, AllbertAssist.External.HttpClient, [])
      |> Keyword.get(:req_plug)
  end

  defp audit_grant_attrs(context) do
    case grant_ids(context) do
      [] -> %{}
      grant_ids -> %{grant_ids: grant_ids}
    end
  end

  defp grant_ids(context) do
    context
    |> GrantHandoff.action_metadata()
    |> get_in([:resource_grants, :grant_ids])
    |> List.wrap()
  end

  defp confirmation_id(%{"id" => id}), do: id
  defp confirmation_id(_confirmation), do: nil

  defp confirmation_metadata(nil), do: nil

  defp confirmation_metadata(confirmation) do
    %{
      id: Map.get(confirmation, "id"),
      status: Map.get(confirmation, "status"),
      origin: Map.get(confirmation, "origin"),
      expires_at: Map.get(confirmation, "expires_at"),
      audit_path: Map.get(confirmation, "audit_path")
    }
  end

  defp origin(context) do
    request = Map.get(context, :request, %{})

    %{
      actor: Map.get(request, :operator_id, Map.get(context, :actor, "local")),
      channel: Map.get(request, :channel, Map.get(context, :channel, :unknown)),
      surface: Map.get(context, :surface, "external_network_request"),
      session_id: Map.get(request, :session_id, Map.get(context, :session_id)),
      response_target: Map.get(context, :response_target)
    }
  end

  defp selected_skill(context) do
    metadata = Map.get(context, :skill_metadata, %{})

    %{
      name: Map.get(context, :selected_skill),
      source_scope: Map.get(metadata, :source_scope),
      trust_status: Map.get(metadata, :trust_status),
      capability_contract: Map.get(metadata, :capability_contract)
    }
  end

  defp capability_contract(context) do
    context
    |> Map.get(:skill_metadata, %{})
    |> Map.get(:capability_contract, %{})
  end

  defp source_signal_id(context) do
    Map.get(context, :runner_requested_signal_id) ||
      get_in(context, [:request, :input_signal_id])
  end

  defp source_trace_id(context) do
    Map.get(context, :trace_id) ||
      get_in(context, [:request, :trace_id])
  end

  defp runner_metadata(context) do
    %{
      requested_signal_id: Map.get(context, :runner_requested_signal_id),
      selected_skill: Map.get(context, :selected_skill),
      selected_action: Map.get(context, :selected_action),
      action_capability: Map.get(context, :action_capability)
    }
  end
end
