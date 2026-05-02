defmodule AllbertAssist.Skills.CapabilityContract do
  @moduledoc """
  Capability contract parsed from Allbert skill metadata.

  The contract never grants permission or causes an action to execute by
  itself. v0.06 validates contracts against registered actions and known
  Security Central permission classes before they can be used for
  skill-backed routing.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Security.Policy

  @known_confirmations %{
    "not_required" => :not_required,
    "future_confirmation_required" => :future_confirmation_required,
    "required" => :required
  }

  defstruct status: :none,
            actions: [],
            permissions: [],
            confirmation: nil,
            memory_effects: [],
            trace_effects: [],
            raw: %{}

  @type status :: :none | :draft | :legacy

  @type t :: %__MODULE__{
          status: status(),
          actions: [String.t()],
          permissions: [String.t()],
          confirmation: nil | String.t(),
          memory_effects: [String.t()],
          trace_effects: [String.t()],
          raw: map()
        }

  @doc "Build a draft contract from parsed `metadata.allbert.*` fields."
  @spec from_metadata(map()) :: t()
  def from_metadata(metadata) when is_map(metadata) do
    actions = list_value(metadata["allbert.actions"])
    permissions = list_value(metadata["allbert.permissions"])

    %__MODULE__{
      status: contract_status(actions, permissions),
      actions: actions,
      permissions: permissions,
      confirmation: string_value(metadata["allbert.confirmation"]),
      memory_effects: list_value(metadata["allbert.memory-effects"]),
      trace_effects: list_value(metadata["allbert.trace-effects"]),
      raw: metadata
    }
  end

  def from_metadata(_metadata), do: %__MODULE__{}

  @doc "Build a legacy bridge contract for pre-M4 built-in declarations."
  @spec legacy(String.t(), atom()) :: t()
  def legacy(action_name, permission) when is_binary(action_name) do
    %__MODULE__{
      status: :legacy,
      actions: [action_name],
      permissions: [to_string(permission)],
      raw: %{"allbert.actions" => action_name, "allbert.permissions" => to_string(permission)}
    }
  end

  @doc "Validate a contract against registered actions and Security Central permissions."
  @spec validate(t(), keyword()) :: map()
  def validate(contract, opts \\ [])

  def validate(%__MODULE__{status: :none}, _opts) do
    %{
      status: :none,
      execution_eligible?: false,
      actions: [],
      permissions: [],
      confirmation: nil,
      diagnostics: []
    }
  end

  def validate(%__MODULE__{} = contract, opts) do
    {actions, action_diagnostics} = validate_actions(contract.actions)
    {permissions, permission_diagnostics} = validate_permissions(contract.permissions)
    {confirmation, confirmation_diagnostics} = validate_confirmation(contract.confirmation)

    diagnostics =
      action_diagnostics ++
        permission_diagnostics ++
        confirmation_diagnostics ++
        workflow_diagnostics(actions) ++ permission_match_diagnostics(actions, permissions)

    status = if Enum.any?(diagnostics, &(&1.severity == :error)), do: :invalid, else: :valid

    %{
      status: status,
      execution_eligible?: status == :valid and execution_eligible?(opts),
      actions: actions,
      permissions: permissions,
      confirmation: confirmation,
      diagnostics: diagnostics
    }
  end

  def validate(_contract, _opts), do: validate(%__MODULE__{}, [])

  defp contract_status([], []), do: :none
  defp contract_status(_actions, _permissions), do: :draft

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: nil

  defp list_value(nil), do: []

  defp list_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp list_value(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp list_value(value), do: [to_string(value)]

  defp validate_actions([]),
    do: {[], [diagnostic(:error, :missing_action, "No action declared.")]}

  defp validate_actions(action_names) do
    action_names
    |> Enum.map(&validate_action/1)
    |> Enum.reduce({[], []}, fn
      {:ok, action}, {actions, diagnostics} -> {[action | actions], diagnostics}
      {:error, diagnostic}, {actions, diagnostics} -> {actions, [diagnostic | diagnostics]}
    end)
    |> then(fn {actions, diagnostics} -> {Enum.reverse(actions), Enum.reverse(diagnostics)} end)
  end

  defp validate_action(action_name) do
    case Registry.capability(action_name) do
      {:ok, capability} ->
        summary = Capability.summary(capability)

        if capability.skill_backed? do
          {:ok, summary}
        else
          {:error,
           diagnostic(
             :error,
             :action_not_skill_backed,
             "Registered action is not available for skill-backed routing.",
             action: capability.name,
             permission: capability.permission
           )}
        end

      {:error, _reason} ->
        {:error,
         diagnostic(:error, :unknown_action, "Unknown or unregistered action.",
           action: action_name
         )}
    end
  end

  defp validate_permissions([]),
    do: {[], [diagnostic(:error, :missing_permission, "No permission declared.")]}

  defp validate_permissions(permissions) do
    permissions
    |> Enum.map(&validate_permission/1)
    |> Enum.reduce({[], []}, fn
      {:ok, permission}, {permissions, diagnostics} ->
        {[permission | permissions], diagnostics}

      {:error, diagnostic}, {permissions, diagnostics} ->
        {permissions, [diagnostic | diagnostics]}
    end)
    |> then(fn {permissions, diagnostics} ->
      {permissions |> Enum.reverse() |> Enum.uniq(), Enum.reverse(diagnostics)}
    end)
  end

  defp validate_permission(permission) do
    permission_string = to_string(permission)

    Policy.permission_classes()
    |> Enum.find(&(to_string(&1) == permission_string))
    |> case do
      nil ->
        {:error,
         diagnostic(:error, :unknown_permission, "Unknown permission class.",
           permission: permission_string
         )}

      permission_atom ->
        {:ok, permission_atom}
    end
  end

  defp validate_confirmation(nil),
    do: {nil, [diagnostic(:error, :missing_confirmation, "No confirmation policy declared.")]}

  defp validate_confirmation(confirmation) do
    confirmation_string = to_string(confirmation)

    case Map.fetch(@known_confirmations, confirmation_string) do
      {:ok, confirmation} ->
        {confirmation, []}

      :error ->
        {nil,
         [
           diagnostic(:error, :unknown_confirmation, "Unknown confirmation policy.",
             confirmation: confirmation_string
           )
         ]}
    end
  end

  defp workflow_diagnostics(actions) when length(actions) > 1 do
    [
      diagnostic(
        :error,
        :multi_action_workflow_not_executable,
        "Multi-action skill workflows are not executable in v0.06.",
        actions: Enum.map(actions, & &1.name)
      )
    ]
  end

  defp workflow_diagnostics(_actions), do: []

  defp permission_match_diagnostics(actions, permissions) do
    action_permissions =
      actions
      |> Enum.map(& &1.permission)
      |> Enum.uniq()

    missing =
      action_permissions
      |> Enum.reject(&(&1 in permissions))
      |> Enum.map(fn permission ->
        diagnostic(
          :error,
          :permission_action_mismatch,
          "Action permission is not declared by the contract.",
          permission: permission
        )
      end)

    extra =
      permissions
      |> Enum.reject(&(&1 in action_permissions))
      |> Enum.map(fn permission ->
        diagnostic(
          :error,
          :permission_without_action,
          "Declared permission is not required by the declared action.",
          permission: permission
        )
      end)

    missing ++ extra
  end

  defp execution_eligible?(opts) do
    case Keyword.get(opts, :skill) do
      %{trust_status: :trusted, enabled?: true} -> true
      %{trust_status: :trusted} = skill -> Map.get(skill, :enabled?, true)
      _other -> false
    end
  end

  defp diagnostic(severity, code, message, extra \\ []) do
    extra
    |> Enum.into(%{severity: severity, code: code, message: message})
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
