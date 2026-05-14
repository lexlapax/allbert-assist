defmodule AllbertAssist.Actions.Intent.UnsupportedResourceWorkflow do
  @moduledoc """
   User-facing deferred response for resource workflows that v0.11 must not run.

   The action is intentionally inert. It gives every current channel the same
   explanation when a request needs a later adapter instead of turning the
   request into a partial fetch, import, file read, or execution path.
  """

  use Jido.Action,
    name: "unsupported_resource_workflow",
    description: "Explain resource workflows that v0.11 does not execute.",
    category: "intent",
    tags: ["intent", "resource", "unsupported", "read_only"],
    schema: [
      workflow: [type: :string, required: true, doc: "Deferred workflow key."],
      source_text: [type: :string, required: false, doc: "Original user request."],
      resource: [type: :string, required: false, doc: "Optional URI or resource hint."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate

  @workflow_aliases %{
    "summarize_url" => :summarize_url,
    "inspect_document" => :inspect_document,
    "read_local_path" => :read_local_path,
    "inspect_local_file" => :read_local_path,
    "unsupported_uri_scheme" => :unsupported_uri_scheme,
    "web_browsing" => :web_browsing,
    "channel_approval_handoff" => :channel_approval_handoff,
    "document_extraction" => :document_extraction
  }

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    workflow = workflow(params)
    resource = text_param(params, :resource)

    {:ok,
     %{
       message: message(workflow, resource),
       status: status(permission_decision),
       permission_decision: permission_decision,
       unsupported_workflow: %{
         workflow: workflow,
         resource: resource,
         v0_10_supported?: false,
         v0_11_supported?: false,
         v0_11_owner: :execution_aware_intent_and_approval_handoff
       },
       actions: [
         %{
           name: "unsupported_resource_workflow",
           status: status(permission_decision),
           permission: :read_only,
           permission_decision: permission_decision,
           execution: :not_started,
           workflow: workflow,
           resource: resource,
           v0_10_supported?: false,
           v0_11_supported?: false
         }
       ]
     }}
  end

  defp workflow(params) do
    params
    |> text_param(:workflow)
    |> normalize_workflow()
  end

  defp normalize_workflow(nil), do: :resource_workflow
  defp normalize_workflow(""), do: :resource_workflow

  defp normalize_workflow(value) do
    normalized =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    Map.get(@workflow_aliases, normalized, :resource_workflow)
  end

  defp status(%{decision: :denied}), do: :denied
  defp status(_decision), do: :unsupported

  defp message(workflow, resource) do
    """
    #{workflow_intro(workflow)}

     v0.11 has not run anything for this request: no fetch, read, extraction, summarization, crawl, MCP call, agent delegation, import, or execution has started.

     What v0.11 can do today is narrower: it can use approved registered resource consumers such as `external_network_request`, online skill source actions, direct skill URL import, local skill directory import, package install actions, shell execution, and trusted skill script execution. Each one has its own Security Central policy, confirmation, resource refs, traces, and audits.

     A later milestone must add any missing bounded reader, parser, browser, MCP, or agent adapter with its own security, confirmation, trace, and test story.
    #{resource_line(resource)}
    """
    |> String.trim()
  end

  defp workflow_intro(:summarize_url) do
    "URL summarization is deferred to v0.11. v0.10 may fetch an approved URL only through explicit registered actions, but it does not fetch a URL and hand it to a summarizer."
  end

  defp workflow_intro(:inspect_document) do
    "Document inspection is deferred to v0.11. v0.10 does not read, download, extract, or summarize arbitrary documents."
  end

  defp workflow_intro(:document_extraction) do
    "Document extraction is unavailable until a registered extractor/parser exists. v0.11 does not parse arbitrary remote or local document formats."
  end

  defp workflow_intro(:read_local_path) do
    "Generic local file inspection is unavailable in v0.11 unless a registered bounded reader exists. There is no shell-command fallback for local reads."
  end

  defp workflow_intro(:unsupported_uri_scheme) do
    "This URI/resource scheme is inert in v0.11. MCP resources and future agent endpoints can be represented for planning, but v0.11 does not call MCP tools or delegate to agent endpoints."
  end

  defp workflow_intro(:web_browsing) do
    "Broad web browsing, crawling, and open internet research are deferred to a later release. v0.11 is not a browser or crawler."
  end

  defp workflow_intro(:channel_approval_handoff) do
    "Channel-native Approval Handoff for future Telegram/email/SMS-style channels is deferred to v0.16+. v0.11 channels do not own approval storage, policy, grants, or execution."
  end

  defp workflow_intro(_workflow) do
    "This resource workflow is deferred beyond v0.11."
  end

  defp resource_line(nil), do: ""
  defp resource_line(""), do: ""
  defp resource_line(resource), do: "\nResource: #{resource}"

  defp text_param(params, key) do
    params
    |> Map.get(key, Map.get(params, Atom.to_string(key)))
    |> normalize_text()
  end

  defp normalize_text(nil), do: nil
  defp normalize_text(value), do: value |> to_string() |> String.trim()
end
