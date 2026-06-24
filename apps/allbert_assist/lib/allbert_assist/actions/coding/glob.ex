defmodule AllbertAssist.Actions.Coding.Glob do
  @moduledoc """
  Expand bounded glob patterns inside the Pi-mode cwd jail.
  """

  use AllbertAssist.Action,
    permission: :coding_file_read,
    exposure: :internal,
    execution_mode: :coding_search,
    skill_backed?: false,
    confirmation: :not_required,
    name: "glob",
    description: "List files matching a glob pattern inside the coding cwd jail.",
    category: "coding",
    tags: ["coding", "read_only", "search"],
    schema: [
      pattern: [type: :string, required: true],
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
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    with {:ok, context} <- SessionGuard.ensure_active(context) do
      permission_decision =
        PermissionGate.authorize(:coding_file_read, action_context(params, context))

      if PermissionGate.allowed?(permission_decision) do
        run_glob(params, permission_decision, context)
      else
        blocked_response(permission_decision)
      end
    else
      {:error, reason, context} ->
        denied_response(reason, SessionGuard.denied_decision(:coding_file_read, context, reason))
    end
  end

  defp run_glob(params, permission_decision, context) do
    opts = [
      max_results: int_param(params, :max_results, Config.search_max_results()),
      max_output_bytes: int_param(params, :max_output_bytes, Config.search_max_output_bytes())
    ]

    case Search.glob(field(params, :pattern), context, opts) do
      {:ok, result} ->
        completed_response(result, permission_decision, opts)

      {:error, reason} ->
        denied_response(reason, permission_decision)
    end
  end

  defp completed_response(result, permission_decision, opts) do
    {rendered, output_truncated?} = Search.render_glob(result, opts)
    truncated? = result.truncated? or output_truncated?

    header =
      "Glob #{inspect(result.pattern)} matches=#{result.match_count} truncated=#{truncated?}"

    payload = String.trim_trailing(header <> "\n" <> rendered)

    {:ok,
     %{
       message: payload,
       model_payload: payload,
       surface_payload: payload,
       status: :completed,
       permission_decision: permission_decision,
       glob: Map.put(result, :truncated?, truncated?),
       actions: [
         %{
           name: "glob",
           status: :completed,
           permission: :coding_file_read,
           permission_decision: permission_decision,
           result: %{
             pattern: result.pattern,
             match_count: result.match_count,
             truncated?: truncated?
           }
         }
       ]
     }}
  end

  defp denied_response(reason, permission_decision) do
    {:ok,
     %{
       message: "Coding glob was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       actions: [
         %{
           name: "glob",
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
         "Coding glob did not run: permission gate returned #{permission_decision.decision}.",
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [
         %{
           name: "glob",
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
      resource: %{kind: :local_glob, access: :read, pattern: field(params, :pattern)}
    })
  end

  defp int_param(params, key, default) do
    case field(params, key) do
      value when is_integer(value) -> value
      _other -> default
    end
  end

  defp field(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp field(_map, _key), do: nil
end
