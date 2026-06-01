defmodule AllbertAssist.Workflows do
  @moduledoc """
  Facade for v0.44 operator-authored workflow YAML.

  Workflow files are inert data under Allbert Home. This facade is a plain
  module because it holds no process state and grants no authority.
  """

  alias AllbertAssist.Workflows.{Expander, Loader, SchemaError, Validator}

  @spec list() :: {:ok, [map()], [term()]} | {:error, term()}
  def list, do: Loader.list_workflows()

  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(workflow_id), do: Loader.load(workflow_id)

  @spec exists?(String.t()) :: boolean()
  def exists?(workflow_id), do: Loader.exists?(workflow_id)

  @spec inspect_workflow(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_workflow(workflow_id, opts \\ []) do
    with {:ok, workflow} <- Loader.load(workflow_id),
         {:ok, workflow} <- Validator.validate(workflow, opts) do
      {:ok, workflow}
    end
  end

  @spec expand(String.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def expand(workflow_id, inputs \\ %{}, context \\ %{}, opts \\ []) do
    with {:ok, workflow} <- inspect_workflow(workflow_id, opts),
         {:ok, workflow} <-
           apply_step_overrides(workflow, Keyword.get(opts, :step_overrides, %{})),
         {:ok, workflow} <- Validator.validate(workflow, opts) do
      Expander.expand(workflow, inputs, context)
    end
  end

  @spec preview(String.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview(workflow_id, inputs \\ %{}, context \\ %{}, opts \\ []) do
    expand(workflow_id, inputs, context, opts)
  end

  defp apply_step_overrides(workflow, nil), do: {:ok, workflow}

  defp apply_step_overrides(workflow, overrides)
       when is_map(overrides) and map_size(overrides) == 0,
       do: {:ok, workflow}

  defp apply_step_overrides(%{"steps" => steps} = workflow, overrides) when is_map(overrides) do
    overrides = stringify_keys(overrides)
    step_overrides = Map.get(overrides, "steps", overrides)
    known_ids = MapSet.new(Enum.map(steps, &Map.get(&1, "id")))
    override_ids = MapSet.new(Map.keys(step_overrides))

    case MapSet.difference(override_ids, known_ids) |> MapSet.to_list() do
      [] ->
        steps
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, []}, fn {step, index}, {:ok, edited} ->
          override = Map.get(step_overrides, Map.get(step, "id"), %{})

          case edit_step(step, override, index) do
            {:ok, nil} -> {:cont, {:ok, edited}}
            {:ok, edited_step} -> {:cont, {:ok, [edited_step | edited]}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
        |> case do
          {:ok, edited_steps} ->
            edited_steps =
              edited_steps
              |> Enum.reverse()
              |> Enum.sort_by(fn {order, index, _step} -> {order, index} end)
              |> Enum.map(fn {_order, _index, step} -> step end)

            {:ok, Map.put(workflow, "steps", edited_steps)}

          {:error, error} ->
            {:error, error}
        end

      unknown ->
        {:error,
         SchemaError.new(
           pointer: "/steps",
           reason: :unknown_step_override,
           expected: "existing step id",
           got: unknown,
           workflow_id: Map.get(workflow, "id")
         )}
    end
  end

  defp apply_step_overrides(workflow, _overrides), do: {:ok, workflow}

  defp edit_step(step, override, index) do
    override = stringify_keys(override)

    if falsey?(Map.get(override, "enabled")) do
      {:ok, nil}
    else
      with {:ok, order} <- step_order(override, index) do
        step =
          if truthy?(Map.get(override, "confirm")) or Map.get(step, "confirm") == true do
            Map.put(step, "confirm", true)
          else
            Map.delete(step, "confirm")
          end

        {:ok, {order, index, step}}
      end
    end
  end

  defp step_order(%{"order" => value}, _index) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> invalid_order(value)
    end
  end

  defp step_order(%{"order" => value}, _index) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp step_order(%{"order" => value}, _index), do: invalid_order(value)
  defp step_order(_override, index), do: {:ok, index}

  defp invalid_order(value) do
    {:error,
     SchemaError.new(
       pointer: "/steps/*/order",
       reason: :invalid_step_order,
       expected: "positive integer",
       got: value
     )}
  end

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_value), do: false

  defp falsey?(value) when value in [false, "false", "0", 0, "off"], do: true
  defp falsey?(_value), do: false

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} -> {to_string(key), stringify_keys(value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
