defmodule AllbertAssist.Actions.Coding.Grep do
  @moduledoc """
  Search text files inside the Pi-mode cwd jail.
  """

  use AllbertAssist.Action,
    permission: :coding_file_read,
    exposure: :internal,
    execution_mode: :coding_search,
    skill_backed?: false,
    confirmation: :not_required,
    name: "grep",
    description: "Search bounded text files inside the coding cwd jail.",
    category: "coding",
    tags: ["coding", "read_only", "search"],
    schema: [
      pattern: [type: :string, required: true],
      path: [type: :string, required: false],
      regex: [type: :boolean, required: false],
      case_sensitive: [type: :boolean, required: false],
      max_results: [type: :integer, required: false],
      max_output_bytes: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Coding.Config
  alias AllbertAssist.Coding.Search
  alias AllbertAssist.Coding.SessionGuard
  alias AllbertAssist.Maps
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    with {:ok, context} <- SessionGuard.ensure_active(context) do
      permission_decision =
        PermissionGate.authorize(:coding_file_read, action_context(params, context))

      if PermissionGate.allowed?(permission_decision) do
        run_grep(params, permission_decision, context)
      else
        blocked_response(permission_decision)
      end
    else
      {:error, reason, context} ->
        denied_response(reason, SessionGuard.denied_decision(:coding_file_read, context, reason))
    end
  end

  defp run_grep(params, permission_decision, context) do
    opts = [
      path: field(params, :path) || ".",
      regex?: truthy?(field(params, :regex)),
      case_sensitive?: field(params, :case_sensitive) not in [false, "false"],
      max_results: int_param(params, :max_results, Config.search_max_results()),
      max_output_bytes: int_param(params, :max_output_bytes, Config.search_max_output_bytes())
    ]

    case Search.grep(field(params, :pattern), context, opts) do
      {:ok, result} ->
        completed_response(result, permission_decision, opts)

      {:error, reason} ->
        denied_response(reason, permission_decision)
    end
  end

  defp completed_response(result, permission_decision, opts) do
    {rendered, output_truncated?} = Search.render_grep(result, opts)
    truncated? = result.truncated? or output_truncated?

    header =
      "Grep #{inspect(result.pattern)} matches=#{result.match_count} " <>
        "files=#{result.searched_file_count} truncated=#{truncated?}"

    payload = String.trim_trailing(header <> "\n" <> rendered)

    {:ok,
     %{
       message: payload,
       model_payload: payload,
       surface_payload: payload,
       status: :completed,
       permission_decision: permission_decision,
       grep: Map.put(result, :truncated?, truncated?),
       actions: [
         %{
           name: "grep",
           status: :completed,
           permission: :coding_file_read,
           permission_decision: permission_decision,
           result: %{
             pattern: result.pattern,
             match_count: result.match_count,
             searched_file_count: result.searched_file_count,
             truncated?: truncated?
           }
         }
       ]
     }}
  end

  defp denied_response(reason, permission_decision) do
    {:ok,
     %{
       message: "Coding grep was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       actions: [
         %{
           name: "grep",
           status: :denied,
           permission: :coding_file_read,
           permission_decision: permission_decision,
           denial_reason: reason
         }
       ]
     }}
  end

  defp blocked_response(permission_decision) do
    {:ok,
     %{
       message:
         "Coding grep did not run: permission gate returned #{permission_decision.decision}.",
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [
         %{
           name: "grep",
           status: PermissionGate.response_status(permission_decision),
           permission: :coding_file_read,
           permission_decision: permission_decision,
           execution: :not_started
         }
       ]
     }}
  end

  defp action_context(params, context) do
    Map.merge(context, %{
      resource: %{kind: :local_search, access: :read, path: field(params, :path) || "."}
    })
  end

  defp truthy?(value), do: value in [true, "true", true]

  defp int_param(params, key, default) do
    case field(params, key) do
      value when is_integer(value) -> value
      _other -> default
    end
  end

  defp field(map, key), do: Maps.field(map, key)
end
