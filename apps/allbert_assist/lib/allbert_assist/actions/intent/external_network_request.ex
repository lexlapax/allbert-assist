defmodule AllbertAssist.Actions.Intent.ExternalNetworkRequest do
  @moduledoc """
  Handles confirmed external HTTP/service requests through the v0.10 Req adapter.

  Request creation validates and records a durable confirmation without making
  a network call. The target request runs only when approve_confirmation resumes
  this action with an approved confirmation context.
  """

  use AllbertAssist.Action,
    permission: :external_network,
    exposure: :agent,
    execution_mode: :req_http,
    skill_backed?: true,
    confirmation: :required,
    resumable?: true,
    notes: "v0.10 confirmed Req HTTP execution; creates a durable confirmation before running.",
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
      operation_class: [type: :string, required: false, doc: "Resource operation class."],
      downstream_consumer: [
        type: :string,
        required: false,
        doc: "Resource consumer after the approved fetch."
      ],
      postprocess: [type: :string, required: false, doc: "Post-fetch consumer workflow."],
      source_text: [type: :string, required: false, doc: "The original user prompt."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.External.HttpClient
  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Resources.GrantHandoff
  alias AllbertAssist.Resources.OperationClass
  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope
  alias AllbertAssist.Runtime.Audit
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) when is_map(params) do
    case RequestSpec.normalize(params, context: context) do
      {:ok, spec} ->
        run_spec(spec, params, context)

      {:error, spec} ->
        denied_response(
          spec,
          params,
          spec_denial_decision(spec.denial_reason),
          spec.denial_reason
        )
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

  defp run_spec(spec, params, context) do
    summary = request_summary(spec, params)

    permission_decision =
      PermissionGate.authorize(:external_network, request_context(spec, context))

    cond do
      permission_decision.decision == :denied ->
        denied_response(
          spec,
          params,
          permission_decision,
          spec.denial_reason || :permission_denied
        )

      approval_resume?(context) ->
        execute_spec(spec, params, permission_decision, context)

      grant_context = grant_execution_context(summary, :external_network, context) ->
        execute_spec(spec, params, permission_decision, grant_context)

      true ->
        create_confirmation(spec, params, context, permission_decision)
    end
  end

  defp denied_response(spec, params, permission_decision, reason) do
    summary = request_summary(spec, params)

    _audit =
      Audit.append(:external_request, :denied, spec, permission_decision, %{
        denial_reason: reason
      })

    {:ok,
     %{
       message: "External network request was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       request: summary,
       actions: [
         %{
           name: "external_network_request",
           status: :denied,
           permission: :external_network,
           permission_decision: permission_decision,
           execution: :not_started,
           request: summary,
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

  defp create_confirmation(spec, params, context, permission_decision) do
    summary = request_summary(spec, params)

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
      params_summary: summary,
      resume_params_ref: Map.merge(RequestSpec.resume_params(spec), consumer_params(params))
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        _audit =
          Audit.append(:external_request, :requested, spec, permission_decision, %{
            confirmation_id: confirmation_id(confirmation)
          })

        {:ok,
         %{
           message: confirmation_message(spec, params, permission_decision, confirmation),
           status: :needs_confirmation,
           permission_decision: permission_decision,
           request: summary,
           confirmation: confirmation,
           confirmation_id: confirmation_id(confirmation),
           actions: [
             %{
               name: "external_network_request",
               status: :needs_confirmation,
               permission: :external_network,
               permission_decision: permission_decision,
               execution: :pending_confirmation,
               request: summary,
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
           request: summary,
           actions: [
             %{
               name: "external_network_request",
               status: :error,
               permission: :external_network,
               permission_decision: permission_decision,
               execution: :not_started,
               request: summary,
               error: reason
             }
           ]
         }}
    end
  end

  defp execute_spec(spec, params, permission_decision, context) do
    confirmation_id = get_in(context, [:confirmation, :id])
    summary = request_summary(spec, params)

    with {:ok, result} <- HttpClient.request(spec, req_opts(context)) do
      result =
        result
        |> Map.put(:request, summary)
        |> Map.put(:postprocess, postprocess_result(result, params))

      _approved_audit =
        Audit.append(
          :external_request,
          :approved,
          spec,
          permission_decision,
          Map.merge(%{confirmation_id: confirmation_id}, audit_grant_attrs(context))
        )

      _result_audit =
        Audit.append(:external_request, result_event(result), spec, permission_decision, %{
          confirmation_id: confirmation_id,
          grant_ids: grant_ids(context),
          result: result
        })

      {:ok,
       %{
         message: execution_message(result, params),
         status: result.status,
         permission_decision: permission_decision,
         request: summary,
         result: result,
         actions: [
           %{
             name: "external_network_request",
             status: result.status,
             permission: :external_network,
             permission_decision: permission_decision,
             execution: :req_http,
             request: summary,
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

  defp request_summary(spec, params) do
    summary = RequestSpec.summary(spec)
    operation_class = operation_class(params)

    if operation_class == :external_service_request do
      summary
    else
      resource_ref = consumer_resource_ref(summary, operation_class, params)

      summary
      |> Map.put(:operation_class, operation_class)
      |> Map.put(:downstream_consumer, downstream_consumer(operation_class, params))
      |> Map.put(:postprocess, postprocess(params) || Atom.to_string(operation_class))
      |> Map.put(:resource_refs, [resource_ref])
    end
  end

  defp consumer_resource_ref(summary, operation_class, params) do
    canonical_url = Map.fetch!(summary, :canonical_url)
    display_url = Map.get(summary, :display_url) || canonical_url

    Ref.new!(%{
      resource_uri: ResourceURI.url!(canonical_url),
      operation_class: operation_class,
      access_mode: OperationClass.default_access_mode(operation_class),
      scope: Scope.exact_url(canonical_url),
      source_profile: Map.get(summary, :profile),
      method: Map.get(summary, :method),
      downstream_consumer: downstream_consumer(operation_class, params),
      display_uri: display_url,
      digest: Map.get(summary, :request_digest),
      limits: Map.take(summary, [:timeout_ms, :max_response_bytes]),
      redaction: %{
        query?: Map.get(summary, :query?),
        request_headers: :redacted_by_policy,
        body: :summarized
      },
      metadata: %{
        display_url: display_url,
        host: Map.get(summary, :host),
        path: Map.get(summary, :path),
        allow_redirects?: Map.get(summary, :allow_redirects?),
        max_redirects: Map.get(summary, :max_redirects),
        retry_policy: Map.get(summary, :retry_policy),
        postprocess: postprocess(params) || Atom.to_string(operation_class)
      }
    })
    |> Ref.to_map()
  end

  defp consumer_params(params) do
    %{}
    |> put_consumer_param(:operation_class, operation_class_param(params))
    |> put_consumer_param(:downstream_consumer, downstream_consumer_param(params))
    |> put_consumer_param(:postprocess, postprocess(params))
  end

  defp put_consumer_param(map, _key, value) when value in [nil, ""], do: map
  defp put_consumer_param(map, key, value), do: Map.put(map, key, value)

  defp operation_class(params) do
    case OperationClass.operation_class(operation_class_param(params)) do
      {:ok, operation_class}
      when operation_class in [:summarize_url, :inspect_document, :external_service_request] ->
        operation_class

      _other ->
        :external_service_request
    end
  end

  defp operation_class_param(params), do: field(params, :operation_class)

  defp downstream_consumer(:summarize_url, params),
    do: downstream_consumer_param(params) || "url_summarizer"

  defp downstream_consumer(:inspect_document, params),
    do: downstream_consumer_param(params) || "document_extractor"

  defp downstream_consumer(_operation_class, params),
    do: downstream_consumer_param(params) || "req_http"

  defp downstream_consumer_param(params), do: field(params, :downstream_consumer)

  defp postprocess(params), do: field(params, :postprocess)

  defp postprocess_result(%{status: :completed, http_status: status}, params) do
    case operation_class(params) do
      :summarize_url ->
        %{
          operation_class: :summarize_url,
          status: :unavailable,
          reason: :summarizer_unavailable,
          http_status: status
        }

      :inspect_document ->
        %{
          operation_class: :inspect_document,
          status: :unavailable,
          reason: :extractor_unavailable,
          http_status: status
        }

      _operation_class ->
        nil
    end
  end

  defp postprocess_result(%{status: :failed}, params) do
    case operation_class(params) do
      operation_class when operation_class in [:summarize_url, :inspect_document] ->
        %{operation_class: operation_class, status: :not_started, reason: :fetch_failed}

      _operation_class ->
        nil
    end
  end

  defp confirmation_message(spec, params, permission_decision, confirmation) do
    """
    External network request is ready for operator approval.

    Request: #{spec.method} #{RequestSpec.redacted_url(spec)}
    Operation: #{operation_class(params)}
    Consumer: #{downstream_consumer(operation_class(params), params)}
    Profile: #{spec.profile}
    Permission gate decision: #{permission_decision.decision} for external_network.
    Confirmation request: #{confirmation_id(confirmation) || "not created"}.
    Nothing has executed yet.
    """
    |> String.trim()
  end

  defp execution_message(%{status: :completed, http_status: status}, params) do
    case operation_class(params) do
      :summarize_url ->
        "URL fetched with HTTP status #{status}. Summarization is unavailable because no summarizer action is registered."

      :inspect_document ->
        "Document URL fetched with HTTP status #{status}. Document extraction is unavailable because no extractor action is registered."

      _operation_class ->
        "External network request completed with HTTP status #{status}."
    end
  end

  defp execution_message(%{status: :failed, http_status: nil, transport_error: error}, _params) do
    "External network request ran but failed before an HTTP response: #{error}."
  end

  defp execution_message(%{status: :failed, http_status: status}, _params) do
    "External network request ran and returned HTTP status #{status}."
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
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
    Origin.from_context(context, "external_network_request")
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
