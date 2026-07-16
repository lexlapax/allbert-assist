defmodule AllbertAssist.Actions.Objectives.DelegateAgent do
  @moduledoc "Dispatch a bounded objective step to a registered delegate agent."

  use AllbertAssist.Action,
    permission: :objective_write,
    exposure: :internal,
    execution_mode: :objective_delegate,
    skill_backed?: false,
    confirmation: :not_required,
    name: "delegate_agent",
    description: "Dispatch a delegated objective step to a registered objective agent.",
    category: "objectives",
    tags: ["objectives", "delegate"],
    schema: [
      user_id: [type: :string, required: true],
      objective_id: [type: :string, required: true],
      step_id: [type: :string, required: true],
      delegate_agent_id: [type: :string, required: true],
      command: [type: {:or, [:string, :atom]}, required: false],
      params: [type: :map, required: false],
      timeout_ms: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Maps
  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:objective_write, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, agent_id} <- agent_id(params),
         {:ok, entry} <- AgentRegistry.lookup(agent_id),
         {:ok, command} <- command(params, entry),
         {:ok, result} <-
           AgentRegistry.dispatch(agent_id, command, field(params, :params, %{}),
             timeout: delegate_timeout_ms(params)
           ) do
      delegate_response = delegate_response(result)
      status = action_status(delegate_response)

      {:ok,
       %{
         message: "Delegated objective step to #{agent_id}.",
         status: status,
         delegate_result: result,
         delegate_response: delegate_response,
         permission_decision: permission_decision,
         confirmation: Map.get(delegate_response, :confirmation),
         confirmation_id: Map.get(delegate_response, :confirmation_id),
         actions: [
           action(status, permission_decision, %{
             delegate_agent_id: agent_id,
             objective_id: field(params, :objective_id),
             step_id: field(params, :step_id),
             command: command
           })
         ]
       }}
    else
      {:allowed, false} ->
        {:ok, denied(permission_decision)}

      {:error, reason} ->
        {:ok, error(permission_decision, reason)}
    end
  end

  defp agent_id(params) do
    case field(params, :delegate_agent_id) || field(params, :agent_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_delegate_agent_id}
    end
  end

  defp command(params, entry) do
    value = field(params, :command, "execute")
    allowed_commands = allowed_commands(entry)

    cond do
      is_atom(value) and Map.has_key?(allowed_commands, Atom.to_string(value)) ->
        {:ok, Map.fetch!(allowed_commands, Atom.to_string(value))}

      is_binary(value) and Map.has_key?(allowed_commands, value) ->
        {:ok, Map.fetch!(allowed_commands, value)}

      true ->
        {:error, :invalid_delegate_command}
    end
  end

  defp allowed_commands(entry) do
    entry
    |> Map.get(:metadata, %{})
    |> metadata_commands()
    |> List.wrap()
    |> Kernel.++([:execute])
    |> Enum.reduce(%{}, fn command, acc ->
      case normalized_allowed_command(command) do
        {:ok, atom} -> Map.put_new(acc, Atom.to_string(atom), atom)
        :error -> acc
      end
    end)
  end

  defp metadata_commands(metadata) when is_map(metadata) do
    Map.get(metadata, :allowed_commands, Map.get(metadata, "allowed_commands", []))
  end

  defp metadata_commands(_metadata), do: []

  defp normalized_allowed_command(command) when is_atom(command), do: {:ok, command}

  defp normalized_allowed_command(command) when is_binary(command) do
    {:ok, String.to_existing_atom(command)}
  rescue
    ArgumentError -> :error
  end

  defp normalized_allowed_command(_command), do: :error

  defp delegate_response(%{state: state}), do: delegate_response_from_state(state)

  defp delegate_response_from_state(state) when is_map(state) do
    case Map.get(state, :last_result, Map.get(state, "last_result")) do
      {:ok, %{} = response} -> response
      {:error, reason} -> %{status: :error, error: reason}
      %{} = response -> response
      _other -> %{}
    end
  end

  defp delegate_response_from_state(_state), do: %{}

  defp action_status(%{status: status}) when status in [:ok, "ok", :completed, "completed"],
    do: :completed

  defp action_status(%{status: status})
       when status in [:needs_confirmation, "needs_confirmation"],
       do: :needs_confirmation

  defp action_status(%{status: status}) when status in [:error, "error"], do: :error
  defp action_status(%{status: status}) when status in [:failed, "failed"], do: :failed
  defp action_status(%{status: status}) when status in [:denied, "denied"], do: :denied
  defp action_status(%{status: status}) when status in [:not_found, "not_found"], do: :not_found
  defp action_status(_delegate_response), do: :completed

  defp delegate_timeout_ms(params) do
    case field(params, :timeout_ms) do
      value when is_integer(value) and value > 0 -> min(value, 900_000)
      _other -> 180_000
    end
  end

  defp denied(permission_decision) do
    Response.denied(permission_decision.reason,
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{error: :permission_denied})]
    )
  end

  defp error(permission_decision, reason) do
    Response.error("Unable to delegate objective step: #{inspect(reason)}", reason,
      permission_decision: permission_decision,
      actions: [action(:error, permission_decision, %{error: reason})]
    )
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "delegate_agent",
      status: status,
      permission: :objective_write,
      permission_decision: permission_decision
    }
    |> Map.merge(metadata)
  end

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)
end
