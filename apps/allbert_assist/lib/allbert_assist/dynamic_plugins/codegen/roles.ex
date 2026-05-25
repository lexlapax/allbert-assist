defmodule AllbertAssist.DynamicPlugins.Codegen.Roles do
  @moduledoc """
  Minimal v0.37.2 generator role pipeline.

  These roles are deterministic wrappers around the injectable LLM provider.
  They make the generator packet shape explicit for later repair/committee work
  without granting authority or starting private durable loops.
  """

  alias AllbertAssist.DynamicPlugins.Codegen.CapabilityGap
  alias AllbertAssist.DynamicPlugins.Codegen.LLM
  alias AllbertAssist.Runtime.Redactor

  @required_generated_fields ~w[description source test_source]

  @doc "Run the bounded role pipeline for one read-only action draft."
  @spec run(CapabilityGap.t(), map(), map(), map()) :: {:ok, [map()], map()} | {:error, term()}
  def run(%CapabilityGap{} = gap, profile, budget, context)
      when is_map(profile) and is_map(budget) and is_map(context) do
    with {:ok, planner} <- plan(gap, profile, budget, context),
         {:ok, author, generated} <- author(gap, profile, budget, context, planner),
         {:ok, trial_author} <- trial_author(generated, planner),
         {:ok, critic} <- critic(generated, planner),
         {:ok, repair} <- repair(critic) do
      {:ok, [planner, author, trial_author, critic, repair], generated}
    end
  end

  defp plan(%CapabilityGap{} = gap, profile, budget, context) do
    {:ok,
     packet("planner", "planned", %{
       "target_shape" => "action",
       "permission_ceiling" => "read_only",
       "gap_id" => gap.id,
       "provider_profile" => Map.get(profile, :name),
       "budget" => Map.take(budget, ["provider_calls_budget", "provider_usage_units_budget"]),
       "request_context" => Redactor.redact(Map.take(context, [:actor, :channel, :surface]))
     })}
  end

  defp author(%CapabilityGap{} = gap, profile, budget, context, planner) do
    with {:ok, generated} <- LLM.generate_action(gap, profile, budget, context) do
      {:ok,
       packet("author", "generated", %{
         "planner_status" => Map.get(planner, "status"),
         "description" => Map.get(generated, "description"),
         "notes" => normalize_list(Map.get(generated, "notes")),
         "usage_units" => usage_units(generated)
       }), generated}
    end
  end

  defp trial_author(generated, planner) do
    with :ok <- require_generated_fields(generated),
         :ok <- require_placeholder(Map.get(generated, "test_source"), "{{TEST_MODULE}}"),
         :ok <- require_placeholder(Map.get(generated, "test_source"), "{{MODULE}}") do
      {:ok,
       packet("trial_author", "test_authored", %{
         "planner_status" => Map.get(planner, "status"),
         "focused_tests" => ["source/test/action_test.exs"]
       })}
    end
  end

  defp critic(generated, planner) do
    with :ok <- require_generated_fields(generated),
         :ok <- require_placeholder(Map.get(generated, "source"), "{{MODULE}}"),
         :ok <- require_placeholder(Map.get(generated, "source"), "{{ACTION_NAME}}"),
         :ok <- require_source_marker(generated, "use AllbertAssist.Action"),
         :ok <- require_source_marker(generated, "permission: :read_only"),
         :ok <- require_source_marker(generated, "confirmation: :not_required") do
      {:ok,
       packet("critic", "accepted", %{
         "planner_status" => Map.get(planner, "status"),
         "checks" => [
           "required_fields",
           "module_placeholders",
           "action_dsl",
           "read_only_permission",
           "no_confirmation"
         ]
       })}
    end
  end

  defp repair(critic) do
    {:ok,
     packet("repair", "not_needed", %{
       "critic_status" => Map.get(critic, "status"),
       "iterations_used" => 0
     })}
  end

  defp require_generated_fields(generated) do
    missing =
      Enum.reject(@required_generated_fields, fn field ->
        generated |> Map.get(field) |> present_string?()
      end)

    case missing do
      [] -> :ok
      _fields -> {:error, {:dynamic_codegen_invalid_generation, %{missing: missing}}}
    end
  end

  defp require_placeholder(value, placeholder) do
    if is_binary(value) and String.contains?(value, placeholder) do
      :ok
    else
      {:error, {:dynamic_codegen_invalid_generation, %{missing_placeholder: placeholder}}}
    end
  end

  defp require_source_marker(generated, marker) do
    source = Map.get(generated, "source")

    if is_binary(source) and String.contains?(source, marker) do
      :ok
    else
      {:error, {:dynamic_codegen_invalid_generation, %{missing_source_marker: marker}}}
    end
  end

  defp packet(role, status, attrs) do
    %{
      "role" => role,
      "status" => status,
      "authority" => "none",
      "metadata" => Redactor.redact(attrs)
    }
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp usage_units(generated) do
    cond do
      is_integer(Map.get(generated, "usage_units")) ->
        Map.get(generated, "usage_units")

      is_integer(get_in(generated, ["usage", "total_tokens"])) ->
        get_in(generated, ["usage", "total_tokens"])

      is_integer(get_in(generated, ["usage", :total_tokens])) ->
        get_in(generated, ["usage", :total_tokens])

      is_integer(get_in(generated, [:usage, :total_tokens])) ->
        get_in(generated, [:usage, :total_tokens])

      true ->
        0
    end
  end

  defp normalize_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp normalize_list(_values), do: []
end
