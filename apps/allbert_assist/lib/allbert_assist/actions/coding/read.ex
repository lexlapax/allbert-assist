defmodule AllbertAssist.Actions.Coding.Read do
  @moduledoc """
  Read a bounded text chunk from a file inside the Pi-mode cwd jail.
  """

  use AllbertAssist.Action,
    permission: :coding_file_read,
    exposure: :agent,
    execution_mode: :coding_file_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "read",
    description: "Read bounded text from a file inside the coding cwd jail.",
    category: "coding",
    tags: ["coding", "read_only", "file"],
    schema: [
      path: [type: :string, required: true],
      offset: [type: :integer, required: false],
      limit: [type: :integer, required: false],
      max_bytes: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Coding.Config
  alias AllbertAssist.Coding.PathPolicy
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision =
      PermissionGate.authorize(:coding_file_read, action_context(params, context))

    if PermissionGate.allowed?(permission_decision) do
      run_read(params, permission_decision, context)
    else
      blocked_response(permission_decision)
    end
  end

  defp run_read(params, permission_decision, context) do
    opts = [
      offset: int_param(params, :offset, 0),
      limit: int_param(params, :limit, Config.read_default_limit()),
      max_bytes: int_param(params, :max_bytes, Config.read_max_bytes())
    ]

    case PathPolicy.read_file(field(params, :path), context, opts) do
      {:ok, file} ->
        completed_response(file, permission_decision)

      {:error, reason} ->
        denied_response(reason, permission_decision)
    end
  end

  defp completed_response(file, permission_decision) do
    header =
      "Read #{file.relative_path} lines offset=#{file.offset} limit=#{file.limit} " <>
        "returned=#{file.returned_lines} truncated=#{file.truncated?}"

    payload = String.trim_trailing(header <> "\n\n" <> file.content)

    {:ok,
     %{
       message: payload,
       model_payload: payload,
       surface_payload: payload,
       status: :completed,
       permission_decision: permission_decision,
       file: file_summary(file),
       actions: [
         %{
           name: "read",
           status: :completed,
           permission: :coding_file_read,
           permission_decision: permission_decision,
           file: file_summary(file)
         }
       ]
     }}
  end

  defp denied_response(reason, permission_decision) do
    {:ok,
     %{
       message: "Coding read was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       actions: [
         %{
           name: "read",
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
         "Coding read did not run: permission gate returned #{permission_decision.decision}.",
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [
         %{
           name: "read",
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
      resource: %{kind: :local_file, access: :read, path: field(params, :path)}
    })
  end

  defp file_summary(file) do
    Map.take(file, [
      :relative_path,
      :byte_size,
      :offset,
      :limit,
      :returned_lines,
      :returned_bytes,
      :truncated?
    ])
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
