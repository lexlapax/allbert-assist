defmodule AllbertAssist.Skills.ActionPlan do
  @moduledoc """
  Validates a selected skill contract before runtime action invocation.

  The plan is inert data. It does not execute actions; it prepares the
  selected skill/action context that the intent agent passes to the action
  runner.
  """

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Skills

  @type t :: %{
          skill: map(),
          action_name: String.t(),
          action_capability: map(),
          params: map(),
          skill_metadata: map()
        }

  @doc "Build an executable plan for one selected skill and one registered action."
  @spec build(String.t(), String.t(), map(), map()) :: {:ok, t()} | {:error, map()}
  def build(skill_name, action_name, params, context \\ %{})
      when is_binary(skill_name) and is_binary(action_name) and is_map(params) and is_map(context) do
    with {:ok, skill} <- Skills.get(skill_name, context),
         {:ok, capability} <- Registry.capability(action_name),
         :ok <- validate_contract(skill, capability) do
      {:ok,
       %{
         skill: skill,
         action_name: capability.name,
         action_capability: Map.from_struct(capability),
         params: params,
         skill_metadata: skill_metadata(skill)
       }}
    else
      {:error, :not_found} ->
        {:error, error(:skill_not_found, "Selected skill is not trusted or enabled.", skill_name)}

      {:error, {:unknown_action, action}} ->
        {:error, error(:unknown_action, "Selected action is not registered.", action)}

      {:error, reason} when is_map(reason) ->
        {:error, reason}
    end
  end

  @doc "Return runner context additions for a validated plan."
  @spec runner_context(t()) :: map()
  def runner_context(plan) do
    %{
      selected_skill: plan.skill.name,
      skill_metadata: plan.skill_metadata,
      action_capability: plan.action_capability
    }
  end

  defp validate_contract(skill, capability) do
    validation = skill.contract_validation || %{}

    cond do
      Map.get(validation, :status) != :valid ->
        {:error,
         error(
           :invalid_contract,
           "Selected skill does not have a valid action-backed contract.",
           skill.name,
           diagnostics: Map.get(validation, :diagnostics, [])
         )}

      Map.get(validation, :execution_eligible?) != true ->
        {:error,
         error(
           :contract_not_execution_eligible,
           "Selected skill contract is not execution-eligible.",
           skill.name
         )}

      not action_declared?(validation, capability.name) ->
        {:error,
         error(
           :action_not_declared_by_skill,
           "Selected action is not declared by the selected skill.",
           capability.name
         )}

      true ->
        :ok
    end
  end

  defp action_declared?(validation, action_name) do
    validation
    |> Map.get(:actions, [])
    |> Enum.any?(&(&1.name == action_name))
  end

  defp skill_metadata(skill) do
    validation = skill.contract_validation || %{}

    %{
      selected_skill: skill.name,
      source_scope: skill.source_scope,
      source_path: skill.source_path,
      trust_status: skill.trust_status,
      kind: skill.kind,
      activation_mode: skill.activation_mode,
      capability_contract: %{
        status: Map.get(skill.capability_contract || %{}, :status, :none),
        actions: Map.get(skill.capability_contract || %{}, :actions, []),
        permissions: Map.get(skill.capability_contract || %{}, :permissions, []),
        validation_status: Map.get(validation, :status, :none),
        execution_eligible?: Map.get(validation, :execution_eligible?, false),
        diagnostics: Map.get(validation, :diagnostics, [])
      }
    }
  end

  defp error(code, message, value, extra \\ []) do
    extra
    |> Enum.into(%{code: code, message: message, value: value})
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
