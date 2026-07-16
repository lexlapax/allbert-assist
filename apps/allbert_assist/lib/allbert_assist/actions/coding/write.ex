defmodule AllbertAssist.Actions.Coding.Write do
  @moduledoc """
  Create a new file inside the Pi-mode cwd jail after operator confirmation.
  """

  use AllbertAssist.Action,
    permission: :coding_file_write,
    exposure: :internal,
    execution_mode: :coding_file_write,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "write",
    description: "Create a new file inside the coding cwd jail.",
    category: "coding",
    tags: ["coding", "file", "write", "confirmation_required"],
    schema: [
      action: [type: :string, required: false],
      path: [type: :string, required: true],
      content: [type: :string, required: true],
      max_bytes: [type: :integer, required: false],
      content_sha256: [type: :string, required: false],
      source_text: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Outbound.Gate
  alias AllbertAssist.Coding.Config
  alias AllbertAssist.Coding.FileEffects
  alias AllbertAssist.Coding.PathPolicy
  alias AllbertAssist.Coding.SessionGuard
  alias AllbertAssist.Maps
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) when is_map(params) do
    with {:ok, context} <- SessionGuard.ensure_active(context) do
      permission_decision =
        PermissionGate.authorize(:coding_file_write, action_context(params, context))

      if permission_decision.decision == :denied do
        blocked_response(permission_decision)
      else
        prepare_and_gate(params, context)
      end
    else
      {:error, reason, context} ->
        denied_response(reason, SessionGuard.denied_decision(:coding_file_write, context, reason))
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:coding_file_write, context)
    denied_response(:invalid_params, permission_decision)
  end

  defp prepare_and_gate(params, context) do
    with {:ok, prepared} <- prepare(params, context) do
      spec = %{
        action_name: "write",
        permission: :coding_file_write,
        execution_mode: :coding_file_write,
        summary: prepared.summary,
        resume_params: resume_params(params, prepared)
      }

      context = action_context(params, context)

      spec
      |> Gate.run(context, fn ->
        FileEffects.write_file(prepared.path, prepared.content, context)
      end)
      |> enrich_response(prepared)
    else
      {:error, reason, permission_decision} ->
        denied_response(reason, permission_decision)
    end
  end

  defp prepare(params, context) do
    content = text_param(params, :content)
    max_bytes = int_param(params, :max_bytes, Config.write_max_bytes())

    with :ok <- ensure_content_size(content, max_bytes),
         {:ok, destination} <- PathPolicy.resolve_new_file(field(params, :path), context) do
      path = destination.relative_path

      summary = %{
        path: path,
        byte_size: byte_size(content),
        content_sha256: FileEffects.sha256(content),
        diff_preview: FileEffects.diff(:write, path, "", content, 1),
        diff_truncated?: FileEffects.diff_truncated?(:write, path, "", content, 1)
      }

      {:ok,
       %{
         path: field(params, :path),
         content: content,
         max_bytes: max_bytes,
         summary: summary
       }}
    else
      {:error, reason} ->
        permission_decision =
          PermissionGate.authorize(:coding_file_write, action_context(params, context))

        {:error, reason, permission_decision}
    end
  end

  defp enrich_response({:ok, response}, prepared) do
    status = Map.get(response, :status, :completed)
    model_payload = model_payload_for(status, response, prepared.summary)
    surface_payload = surface_payload_for(status, response, prepared.summary)

    {:ok,
     response
     |> Map.put(:model_payload, model_payload)
     |> Map.put(:surface_payload, surface_payload)
     |> Map.put(:output_data, output_data(response, prepared.summary))}
  end

  defp model_payload_for(:completed, response, _summary) do
    receipt = Map.get(response, :receipt, %{})

    "write completed: #{Map.get(receipt, :relative_path, "unknown")} bytes=#{Map.get(receipt, :byte_size, 0)} content_sha256=#{Map.get(receipt, :content_sha256, "unknown")} diff_truncated=#{Map.get(receipt, :diff_truncated?, false)}"
  end

  defp model_payload_for(:needs_confirmation, response, summary) do
    [
      Map.get(response, :message, "write needs confirmation"),
      "\npath=",
      summary.path,
      " bytes=",
      to_string(summary.byte_size),
      " content_sha256=",
      summary.content_sha256,
      " diff_truncated=",
      to_string(summary.diff_truncated?)
    ]
    |> IO.iodata_to_binary()
  end

  defp model_payload_for(_status, response, _summary), do: Map.get(response, :message, "")

  defp surface_payload_for(:completed, response, _summary) do
    receipt = Map.get(response, :receipt, %{})

    [
      "write completed: ",
      Map.get(receipt, :relative_path, "unknown"),
      " bytes=",
      receipt |> Map.get(:byte_size, 0) |> to_string(),
      "\n\n",
      Map.get(receipt, :diff, "")
    ]
    |> IO.iodata_to_binary()
  end

  defp surface_payload_for(:needs_confirmation, response, summary) do
    [
      Map.get(response, :message, "write needs confirmation"),
      "\npath=",
      summary.path,
      " bytes=",
      to_string(summary.byte_size),
      " content_sha256=",
      summary.content_sha256,
      "\n\n",
      summary.diff_preview
    ]
    |> IO.iodata_to_binary()
  end

  defp surface_payload_for(_status, response, _summary), do: Map.get(response, :message, "")

  defp output_data(response, summary) do
    response
    |> Map.get(:receipt, summary)
    |> Map.take([:relative_path, :byte_size, :content_sha256, :diff_truncated?])
  end

  defp resume_params(params, prepared) do
    %{
      action: "write",
      path: prepared.path,
      content: prepared.content,
      max_bytes: prepared.max_bytes,
      content_sha256: prepared.summary.content_sha256,
      source_text: field(params, :source_text)
    }
  end

  defp blocked_response(permission_decision) do
    {:ok,
     %{
       message:
         "Coding write did not run: permission gate returned #{permission_decision.decision}.",
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [
         %{
           name: "write",
           status: PermissionGate.response_status(permission_decision),
           permission: :coding_file_write,
           permission_decision: permission_decision,
           execution: :not_started
         }
       ]
     }}
  end

  defp denied_response(reason, permission_decision) do
    {:ok,
     %{
       message: "Coding write was denied: #{inspect(reason)}.",
       status: :denied,
       error: reason,
       permission_decision: permission_decision,
       actions: [
         %{
           name: "write",
           status: :denied,
           permission: :coding_file_write,
           permission_decision: permission_decision,
           execution: :not_started,
           denial_reason: reason
         }
       ]
     }}
  end

  defp action_context(params, context) do
    Map.merge(context, %{
      request: normalized_request(context),
      resource: %{kind: :local_file, access: :write, path: field(params, :path)}
    })
  end

  defp normalized_request(context) do
    context
    |> Map.get(:request, %{})
    |> Map.put(:channel, channel_name(context))
  end

  defp channel_name(%{channel: %{name: name}}), do: name
  defp channel_name(%{"channel" => %{"name" => name}}), do: name
  defp channel_name(%{channel: channel}), do: channel
  defp channel_name(%{"channel" => channel}), do: channel
  defp channel_name(_context), do: :unknown

  defp ensure_content_size(content, max_bytes) when byte_size(content) <= max_bytes, do: :ok

  defp ensure_content_size(content, max_bytes),
    do: {:error, {:content_too_large, byte_size(content), max_bytes}}

  defp int_param(params, key, default) do
    case field(params, key) do
      value when is_integer(value) -> value
      _other -> default
    end
  end

  defp text_param(params, key) do
    case field(params, key) do
      value when is_binary(value) -> value
      nil -> ""
      value -> to_string(value)
    end
  end

  defp field(map, key), do: Maps.field(map, key)
end
