defmodule AllbertAssist.Workflows.Validator do
  @moduledoc """
  Strict workflow YAML validator.

  JSON Schema catches structural drift; this module adds Allbert-specific
  authority and reference invariants that JSON Schema cannot express cleanly.
  """

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.Workflows.{Schema, SchemaError}

  @top_keys ~w[id version description owner inputs steps if]
  @input_keys ~w[name type required default description]
  @common_step_keys ~w[id kind if save_as confirm on_error]
  @kind_keys %{
    "action" => ~w[action params],
    "ask_user" => ~w[prompt options],
    "wait" => ~w[until for_ms match],
    "observe" => ~w[signal match],
    "reflect" => ~w[prompt inputs],
    "delegate_agent" => ~w[delegate_agent_id command params]
  }
  @input_types ~w[string integer number boolean]
  @forbidden_substitution_paths ~w[id kind action delegate_agent_id save_as]
  @reserved_ref_roots ~w[inputs steps user workflow]
  @allowed_functions ~w[length contains starts_with ends_with lower upper default to_json from_json]
  @jsv_keyword_reasons %{
    "additionalProperties" => :unknown_key,
    :additionalProperties => :unknown_key,
    "required" => :missing_required,
    :required => :missing_required,
    "type" => :type_mismatch,
    :type => :type_mismatch,
    "const" => :type_mismatch,
    :const => :type_mismatch
  }

  @spec validate(map(), keyword()) :: {:ok, map()} | {:error, SchemaError.t()}
  def validate(workflow, opts \\ [])

  def validate(%{} = workflow, opts) do
    action_modules = Keyword.get(opts, :action_modules, Registry.modules())
    workflow_id = Map.get(workflow, "id")

    with :ok <- validate_unknown_keys(workflow, @top_keys, "/", workflow_id),
         :ok <- validate_cap(workflow, workflow_id),
         :ok <- validate_inputs(workflow, workflow_id),
         :ok <- validate_steps(workflow, action_modules),
         :ok <- validate_references(workflow),
         :ok <- validate_with_jsv(workflow, action_modules) do
      {:ok, workflow}
    end
  end

  def validate(_workflow, _opts), do: {:error, error("/", :type_mismatch, expected: "object")}

  @spec resolve_inputs(map(), map()) :: {:ok, map()} | {:error, SchemaError.t()}
  def resolve_inputs(workflow, supplied_inputs \\ %{}) do
    declared = Map.get(workflow, "inputs", [])
    supplied_inputs = stringify_keys(supplied_inputs)

    with :ok <- reject_unknown_inputs(declared, supplied_inputs, workflow),
         {:ok, resolved} <- resolve_declared_inputs(declared, supplied_inputs, workflow) do
      {:ok, resolved}
    end
  end

  defp validate_with_jsv(workflow, action_modules) do
    root = Schema.root(action_modules)

    case JSV.validate(workflow, root) do
      {:ok, _data} ->
        :ok

      {:error, validation_error} ->
        normalized = JSV.normalize_error(validation_error)
        first = first_jsv_error(normalized)

        {:error,
         error(first.pointer, first.reason,
           expected: first.expected,
           got: first.got,
           workflow_id: Map.get(workflow, "id")
         )}
    end
  rescue
    exception ->
      {:error,
       error("/", :invalid_schema,
         got: Exception.message(exception),
         workflow_id: Map.get(workflow, "id")
       )}
  end

  defp validate_cap(workflow, workflow_id) do
    steps = Map.get(workflow, "steps", [])
    max_steps = max_steps_per_workflow()

    if is_list(steps) and length(steps) <= max_steps do
      :ok
    else
      {:error,
       error("/steps", :cap_exceeded,
         expected: "<= #{max_steps}",
         got: length(List.wrap(steps)),
         workflow_id: workflow_id
       )}
    end
  end

  defp validate_inputs(workflow, workflow_id) do
    inputs = Map.get(workflow, "inputs", [])

    with true <-
           is_list(inputs) || {:error, error("/inputs", :type_mismatch, workflow_id: workflow_id)},
         :ok <- validate_unique(inputs, "name", "/inputs", workflow_id) do
      Enum.reduce_while(Enum.with_index(inputs), :ok, fn {input, index}, :ok ->
        input
        |> validate_input(index, workflow_id)
        |> reduce_result()
      end)
    end
  end

  defp validate_input(input, index, workflow_id) do
    pointer = "/inputs/#{index}"

    with :ok <- validate_unknown_keys(input, @input_keys, pointer, workflow_id),
         :ok <- validate_input_default(input, pointer, workflow_id) do
      :ok
    end
  end

  defp validate_steps(workflow, action_modules) do
    workflow_id = Map.get(workflow, "id")
    steps = Map.get(workflow, "steps", [])
    action_names = MapSet.new(Enum.map(action_modules, & &1.name()))

    with true <-
           is_list(steps) || {:error, error("/steps", :type_mismatch, workflow_id: workflow_id)},
         :ok <- validate_unique(steps, "id", "/steps", workflow_id) do
      Enum.reduce_while(Enum.with_index(steps), :ok, fn {step, index}, :ok ->
        step
        |> validate_step(index, workflow_id, action_names)
        |> reduce_result()
      end)
    end
  end

  defp validate_step(%{} = step, index, workflow_id, action_names) do
    pointer = "/steps/#{index}"
    kind = Map.get(step, "kind")
    allowed = @common_step_keys ++ Map.get(@kind_keys, kind, [])

    with :ok <- validate_unknown_keys(step, allowed, pointer, workflow_id),
         :ok <- validate_on_error(step, pointer, workflow_id),
         :ok <- reject_forbidden_substitution_fields(step, pointer, workflow_id),
         :ok <- validate_kind_specific(step, pointer, workflow_id, action_names) do
      :ok
    end
  end

  defp validate_step(_step, index, workflow_id, _action_names),
    do: {:error, error("/steps/#{index}", :type_mismatch, workflow_id: workflow_id)}

  defp validate_on_error(step, pointer, workflow_id) do
    case Map.get(step, "on_error", "abort") do
      value when value in ["abort", "continue"] ->
        :ok

      value ->
        {:error,
         error(pointer <> "/on_error", :type_mismatch,
           expected: "abort|continue",
           got: value,
           workflow_id: workflow_id
         )}
    end
  end

  defp validate_kind_specific(%{"kind" => "action"} = step, pointer, workflow_id, action_names) do
    action = Map.get(step, "action")

    cond do
      is_binary(action) and String.contains?(action, "${") ->
        {:error, error(pointer <> "/action", :dynamic_action_name, workflow_id: workflow_id)}

      action not in action_names ->
        {:error,
         error(pointer <> "/action", :unknown_action, got: action, workflow_id: workflow_id)}

      true ->
        validate_param_bytes(Map.get(step, "params", %{}), pointer <> "/params", workflow_id)
    end
  end

  defp validate_kind_specific(%{"kind" => "wait"} = step, pointer, workflow_id, _action_names) do
    has_until = Map.has_key?(step, "until")
    has_for_ms = Map.has_key?(step, "for_ms")

    if has_until != has_for_ms do
      :ok
    else
      {:error,
       error(pointer, :missing_required,
         expected: "exactly one of until or for_ms",
         workflow_id: workflow_id
       )}
    end
  end

  defp validate_kind_specific(
         %{"kind" => "delegate_agent", "delegate_agent_id" => delegate_agent_id},
         pointer,
         workflow_id,
         _action_names
       ) do
    case AgentRegistry.lookup(delegate_agent_id) do
      {:ok, _agent} ->
        :ok

      {:error, _reason} ->
        {:error,
         error(pointer <> "/delegate_agent_id", :unknown_delegate_agent,
           got: delegate_agent_id,
           workflow_id: workflow_id
         )}
    end
  end

  defp validate_kind_specific(%{"kind" => kind}, _pointer, _workflow_id, _action_names)
       when kind in ["ask_user", "observe", "reflect"],
       do: :ok

  defp validate_kind_specific(%{"kind" => kind}, pointer, workflow_id, _action_names),
    do:
      {:error, error(pointer <> "/kind", :unknown_step_kind, got: kind, workflow_id: workflow_id)}

  defp validate_references(workflow) do
    declared_inputs = workflow |> Map.get("inputs", []) |> MapSet.new(&Map.get(&1, "name"))
    steps = Map.get(workflow, "steps", [])

    Enum.reduce_while(Enum.with_index(steps), :ok, fn {step, index}, :ok ->
      previous_step_ids =
        steps |> Enum.take(index) |> Enum.map(&Map.get(&1, "id")) |> MapSet.new()

      current_step_id = Map.get(step, "id")

      case validate_value_references(
             step,
             "/steps/#{index}",
             declared_inputs,
             previous_step_ids,
             current_step_id
           ) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_value_references(
         value,
         pointer,
         declared_inputs,
         previous_step_ids,
         current_step_id
       )
       when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
      validate_value_references(
        nested,
        pointer <> "/" <> escape_pointer(key),
        declared_inputs,
        previous_step_ids,
        current_step_id
      )
      |> reduce_result()
    end)
  end

  defp validate_value_references(
         value,
         pointer,
         declared_inputs,
         previous_step_ids,
         current_step_id
       )
       when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {nested, index}, :ok ->
      validate_value_references(
        nested,
        pointer <> "/#{index}",
        declared_inputs,
        previous_step_ids,
        current_step_id
      )
      |> reduce_result()
    end)
  end

  defp validate_value_references(
         value,
         pointer,
         declared_inputs,
         previous_step_ids,
         current_step_id
       )
       when is_binary(value) do
    value
    |> substitutions()
    |> Enum.reduce_while(:ok, fn expression, :ok ->
      validate_expression(
        expression,
        pointer,
        declared_inputs,
        previous_step_ids,
        current_step_id
      )
      |> reduce_result()
    end)
  end

  defp validate_value_references(
         _value,
         _pointer,
         _declared_inputs,
         _previous_step_ids,
         _current_step_id
       ),
       do: :ok

  defp validate_expression(
         expression,
         pointer,
         declared_inputs,
         previous_step_ids,
         current_step_id
       ) do
    cond do
      Regex.match?(~r/(^|[^a-z_])secrets\./, expression) ->
        {:error, error(pointer, :secret_substitution_attempt)}

      Regex.match?(~r/(^|[^a-z_])env\./, expression) ->
        {:error, error(pointer, :env_substitution_attempt)}

      unknown_function = unknown_function(expression) ->
        {:error, error(pointer, :invalid_expression, got: unknown_function)}

      true ->
        expression
        |> references()
        |> Enum.reduce_while(:ok, fn reference, :ok ->
          validate_reference(
            reference,
            pointer,
            declared_inputs,
            previous_step_ids,
            current_step_id
          )
          |> reduce_result()
        end)
    end
  end

  defp validate_reference(
         "inputs." <> name,
         pointer,
         declared_inputs,
         _previous_step_ids,
         _current_step_id
       ) do
    input = name |> String.split(".", parts: 2) |> List.first()

    if MapSet.member?(declared_inputs, input) do
      :ok
    else
      {:error, error(pointer, :invalid_reference, got: "inputs." <> input)}
    end
  end

  defp validate_reference(
         "steps." <> rest,
         pointer,
         _declared_inputs,
         previous_step_ids,
         current_step_id
       ) do
    [step_id | _field] = String.split(rest, ".", parts: 2)

    cond do
      step_id == current_step_id ->
        {:error, error(pointer, :cycle, got: "steps." <> rest)}

      MapSet.member?(previous_step_ids, step_id) ->
        :ok

      true ->
        {:error, error(pointer, :forward_ref, got: "steps." <> rest)}
    end
  end

  defp validate_reference(
         ref,
         _pointer,
         _declared_inputs,
         _previous_step_ids,
         _current_step_id
       )
       when ref in ["user.locale", "user.timezone", "workflow.id", "workflow.version"],
       do: :ok

  defp validate_reference(
         ref,
         pointer,
         _declared_inputs,
         _previous_step_ids,
         _current_step_id
       ) do
    root = ref |> String.split(".", parts: 2) |> List.first()

    if root in @reserved_ref_roots do
      {:error, error(pointer, :invalid_reference, got: ref)}
    else
      :ok
    end
  end

  defp reject_forbidden_substitution_fields(step, pointer, workflow_id) do
    Enum.reduce_while(@forbidden_substitution_paths, :ok, fn key, :ok ->
      step
      |> validate_forbidden_substitution_field(key, pointer, workflow_id)
      |> reduce_result()
    end)
  end

  defp validate_forbidden_substitution_field(step, key, pointer, workflow_id) do
    case Map.get(step, key) do
      value when is_binary(value) ->
        reject_forbidden_substitution_value(value, key, pointer, workflow_id)

      _other ->
        :ok
    end
  end

  defp reject_forbidden_substitution_value(value, key, pointer, workflow_id) do
    if substitutions(value) == [] do
      :ok
    else
      reason = if key == "action", do: :dynamic_action_name, else: :invalid_expression
      {:error, error(pointer <> "/" <> key, reason, workflow_id: workflow_id)}
    end
  end

  defp validate_param_bytes(params, pointer, workflow_id) do
    case Jason.encode(params || %{}) do
      {:ok, json} ->
        max = max_param_bytes_per_step()

        if byte_size(json) <= max do
          :ok
        else
          {:error,
           error(pointer, :cap_exceeded,
             expected: "<= #{max} bytes",
             got: "#{byte_size(json)} bytes",
             workflow_id: workflow_id
           )}
        end

      {:error, reason} ->
        {:error, error(pointer, :type_mismatch, got: inspect(reason), workflow_id: workflow_id)}
    end
  end

  defp validate_input_default(%{"default" => value, "type" => type}, pointer, workflow_id) do
    if input_type?(value, type) do
      :ok
    else
      {:error,
       error(
         pointer <> "/default",
         :type_mismatch,
         expected: type,
         got: type_name(value),
         workflow_id: workflow_id
       )}
    end
  end

  defp validate_input_default(_input, _pointer, _workflow_id), do: :ok

  defp reject_unknown_inputs(declared, supplied, workflow) do
    declared_names = MapSet.new(declared, &Map.get(&1, "name"))

    case Enum.find(Map.keys(supplied), &(not MapSet.member?(declared_names, &1))) do
      nil -> :ok
      key -> {:error, error("/inputs/#{key}", :unknown_key, workflow_id: Map.get(workflow, "id"))}
    end
  end

  defp resolve_declared_inputs(declared, supplied, workflow) do
    Enum.reduce_while(declared, {:ok, %{}}, fn input, {:ok, acc} ->
      name = Map.fetch!(input, "name")
      type = Map.fetch!(input, "type")
      required? = Map.get(input, "required", true)

      cond do
        Map.has_key?(supplied, name) and input_type?(Map.fetch!(supplied, name), type) ->
          {:cont, {:ok, Map.put(acc, name, Map.fetch!(supplied, name))}}

        Map.has_key?(supplied, name) ->
          {:halt,
           {:error,
            error("/inputs/#{name}", :type_mismatch,
              expected: type,
              got: type_name(Map.fetch!(supplied, name)),
              workflow_id: Map.get(workflow, "id")
            )}}

        Map.has_key?(input, "default") ->
          {:cont, {:ok, Map.put(acc, name, Map.fetch!(input, "default"))}}

        required? ->
          {:halt,
           {:error,
            error("/inputs/#{name}", :missing_required, workflow_id: Map.get(workflow, "id"))}}

        true ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp validate_unknown_keys(map, allowed, pointer, workflow_id) do
    case Enum.find(Map.keys(map), &(&1 not in allowed)) do
      nil ->
        :ok

      key ->
        {:error, error(pointer_child(pointer, key), :unknown_key, workflow_id: workflow_id)}
    end
  end

  defp validate_unique(list, key, pointer, workflow_id) do
    values = Enum.map(list, &Map.get(&1, key))

    duplicate =
      values
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.find(fn {_value, count} -> count > 1 end)

    case duplicate do
      nil ->
        :ok

      {value, _count} ->
        {:error, error(pointer, :invalid_id_pattern, got: value, workflow_id: workflow_id)}
    end
  end

  defp input_type?(value, "string"), do: is_binary(value)
  defp input_type?(value, "integer"), do: is_integer(value)
  defp input_type?(value, "number"), do: is_number(value)
  defp input_type?(value, "boolean"), do: is_boolean(value)
  defp input_type?(_value, type), do: type in @input_types

  defp substitutions(value) do
    Regex.scan(~r/\$\{([^}]+)\}/, value, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
  end

  defp references(expression) do
    Regex.scan(~r/\b(?:inputs|steps|user|workflow)\.[A-Za-z0-9_.]+/, expression)
    |> List.flatten()
  end

  defp unknown_function(expression) do
    Regex.scan(~r/\b([a-z_][a-z0-9_]*)\s*\(/, expression, capture: :all_but_first)
    |> List.flatten()
    |> Enum.find(&(&1 not in @allowed_functions))
  end

  defp first_jsv_error(%{"errors" => [first | _rest]}), do: jsv_error(first)

  defp first_jsv_error(other),
    do: %{pointer: "/", reason: :type_mismatch, expected: nil, got: other}

  defp jsv_error(error) when is_map(error) do
    %{
      pointer:
        Map.get(error, "instanceLocation") || Map.get(error, :instanceLocation) ||
          Map.get(error, "data_path") || Map.get(error, :data_path) || "/",
      reason: jsv_reason(error),
      expected: Map.get(error, "schemaLocation") || Map.get(error, :schemaLocation),
      got: Map.get(error, "value") || Map.get(error, :value)
    }
  end

  defp jsv_error(other), do: %{pointer: "/", reason: :type_mismatch, expected: nil, got: other}

  defp jsv_reason(error) do
    keyword = Map.get(error, "keyword") || Map.get(error, :keyword)
    Map.get(@jsv_keyword_reasons, keyword, :type_mismatch)
  end

  defp reduce_result(:ok), do: {:cont, :ok}
  defp reduce_result({:error, error}), do: {:halt, {:error, error}}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "number"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_map(value), do: "object"
  defp type_name(value) when is_list(value), do: "array"
  defp type_name(nil), do: "null"
  defp type_name(_value), do: "unknown"

  defp max_steps_per_workflow do
    case Settings.get("workflows.max_steps_per_workflow") do
      {:ok, max} when is_integer(max) -> max
      _other -> 3
    end
  end

  defp max_param_bytes_per_step do
    case Settings.get("workflows.max_param_bytes_per_step") do
      {:ok, max} when is_integer(max) -> max
      _other -> 65_536
    end
  end

  defp escape_pointer(value) do
    value
    |> to_string()
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  defp pointer_child("/", key), do: "/" <> escape_pointer(key)
  defp pointer_child(pointer, key), do: pointer <> "/" <> escape_pointer(key)

  defp error(pointer, reason, attrs \\ []) do
    attrs
    |> Keyword.put(:pointer, pointer)
    |> Keyword.put(:reason, reason)
    |> SchemaError.new()
  end
end
