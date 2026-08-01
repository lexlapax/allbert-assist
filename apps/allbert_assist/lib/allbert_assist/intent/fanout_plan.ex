defmodule AllbertAssist.Intent.FanoutPlan do
  @moduledoc """
  A compiled, inert plan for bounded Objective fan-out.

  A plan contains no action, permission, identity, confirmation, scheduling, or
  execution fields. Model output can propose only the human-readable child
  fields accepted here. The compiler owns ordering, cardinality, request
  binding, and conversion to durable Objective attributes; Security Central and
  the Objective runtime retain all authority after that conversion.

  This is a pure value module. A process or Jido Agent would add lifecycle
  machinery without adding useful state-machine depth.
  """

  alias AllbertAssist.Objectives.AcceptanceCriteria

  @allowed_child_keys ~w[title objective expected_result]
  @default_max_children 8
  @absolute_max_children 16
  @max_original_request_bytes 4_000
  @title_limit 200
  @objective_limit 2_000
  @expected_result_limit 500
  @acceptance_criteria_limit 2_000
  @counted_expected_result "Return a useful, factual result that completes this task."
  @child_binding_key "fanout_child"

  @enforce_keys [
    :original_request,
    :original_request_sha256,
    :plan_sha256,
    :source,
    :children
  ]
  defstruct [:original_request, :original_request_sha256, :plan_sha256, :source, :children]

  @type child :: %{required(String.t()) => String.t()}

  @type source :: :model | :exact_counted
  @type t :: %__MODULE__{
          original_request: String.t(),
          original_request_sha256: String.t(),
          plan_sha256: String.t(),
          source: source(),
          children: [child()]
        }

  @doc "Compile bounded advisory child data into an inert, request-bound plan."
  @spec compile(String.t(), [map()], keyword()) :: {:ok, t()} | {:error, term()}
  def compile(original_request, children, opts \\ [])

  def compile(original_request, children, opts)
      when is_binary(original_request) and is_list(children) and is_list(opts) do
    case compile_admission(original_request, children, opts) do
      {:ok, plan} ->
        {:ok, plan}

      {:clarify, %{task_count: count, max_children: max}} ->
        {:error, {:too_many_children, count, max}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def compile(_original_request, _children, _opts), do: {:error, :invalid_original_request}

  @doc "Compile an admission plan, preserving a safe complete-list overflow for operator UX."
  @spec compile_admission(String.t(), [map()], keyword()) ::
          {:ok, t()} | {:clarify, map()} | {:error, term()}
  def compile_admission(original_request, children, opts \\ [])

  def compile_admission(original_request, children, opts)
      when is_binary(original_request) and is_list(children) and is_list(opts) do
    with :ok <- validate_original_request(original_request),
         {:ok, max_children} <- max_children(opts),
         :ok <- validate_minimum_child_count(children),
         {:ok, normalized} <- normalize_children(children),
         :ok <- validate_unique_children(normalized),
         {:ok, source} <- source(opts) do
      if length(normalized) > max_children do
        {:clarify,
         %{
           task_count: length(normalized),
           max_children: max_children,
           tasks: Enum.map(normalized, & &1["objective"])
         }}
      else
        {:ok, build(original_request, normalized, source)}
      end
    end
  end

  def compile_admission(_original_request, _children, _opts),
    do: {:error, :invalid_original_request}

  @doc """
  Compile the frozen exact-counted grammar after its caller has parsed the task list.

  Counted strings are converted locally, so no model controls child field names
  or runtime authority. The full task remains the Objective while its title is a
  bounded display projection.
  """
  @spec compile_counted(String.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def compile_counted(original_request, tasks, opts \\ [])

  def compile_counted(original_request, tasks, opts) when is_list(tasks) and is_list(opts) do
    case compile_counted_admission(original_request, tasks, opts) do
      {:ok, plan} ->
        {:ok, plan}

      {:clarify, %{task_count: count, max_children: max}} ->
        {:error, {:too_many_children, count, max}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def compile_counted(_original_request, _tasks, _opts),
    do: {:error, {:invalid_counted_task, 0}}

  @doc "Compile a counted admission plan, validating every child before overflow clarification."
  @spec compile_counted_admission(String.t(), [String.t()], keyword()) ::
          {:ok, t()} | {:clarify, map()} | {:error, term()}
  def compile_counted_admission(original_request, tasks, opts \\ [])

  def compile_counted_admission(original_request, tasks, opts)
      when is_list(tasks) and is_list(opts) do
    with {:ok, children} <- counted_children(tasks) do
      compile_admission(original_request, children, Keyword.put(opts, :source, :exact_counted))
    end
  end

  def compile_counted_admission(_original_request, _tasks, _opts),
    do: {:error, {:invalid_counted_task, 0}}

  @doc "Project the ordered plan into attributes accepted by `Objectives.Fanout.frame/2`."
  @spec child_attrs(t()) :: [map()]
  def child_attrs(%__MODULE__{children: children} = plan) do
    children
    |> Enum.with_index()
    |> Enum.map(fn {child, index} ->
      %{
        title: child["title"],
        objective: child["objective"],
        acceptance_criteria: AcceptanceCriteria.encode!(%{"summary" => child["expected_result"]}),
        proposer_hint: child_binding(plan.plan_sha256, index, child)
      }
    end)
  end

  @doc "Verify one durable child still matches its compact compiled-plan binding."
  @spec child_binding_valid?(String.t(), non_neg_integer(), child(), String.t() | map() | nil) ::
          boolean()
  def child_binding_valid?(plan_sha256, index, child, encoded_binding)
      when is_binary(plan_sha256) and is_integer(index) and index >= 0 and is_map(child) do
    with {:ok, binding} <- decode_child_binding(encoded_binding),
         %{
           @child_binding_key => %{
             "version" => 1,
             "plan_sha256" => ^plan_sha256,
             "index" => ^index,
             "child_sha256" => child_sha256
           }
         } <- binding,
         true <- binding_keys_valid?(binding),
         true <- is_binary(child_sha256) and byte_size(child_sha256) == 64 do
      child_sha256 == child_digest(plan_sha256, index, child)
    else
      _invalid -> false
    end
  end

  def child_binding_valid?(_plan_sha256, _index, _child, _encoded_binding), do: false

  @doc "Return bounded JSON-safe plan provenance for durable parent metadata."
  @spec provenance(t()) :: map()
  def provenance(%__MODULE__{} = plan) do
    %{
      "version" => 1,
      "source" => provenance_source(plan.source),
      "original_request_sha256" => plan.original_request_sha256,
      "plan_sha256" => plan.plan_sha256
    }
  end

  defp validate_original_request(text) do
    cond do
      String.trim(text) == "" -> {:error, :invalid_original_request}
      byte_size(text) > @max_original_request_bytes -> {:error, :original_request_too_large}
      true -> :ok
    end
  end

  defp max_children(opts) do
    case Keyword.get(opts, :max_children, @default_max_children) do
      value when is_integer(value) and value >= 2 and value <= @absolute_max_children ->
        {:ok, value}

      value ->
        {:error, {:invalid_max_children, value}}
    end
  end

  defp validate_minimum_child_count(children) when length(children) < 2,
    do: {:error, :fanout_requires_at_least_two_children}

  defp validate_minimum_child_count(_children), do: :ok

  defp normalize_children(children) do
    children
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {child, index}, {:ok, acc} ->
      case normalize_child(child, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_child(child, index) when is_map(child) do
    with {:ok, fields} <- normalize_child_keys(child, index),
         {:ok, title} <- child_text(fields, "title", @title_limit, index),
         {:ok, objective} <- child_text(fields, "objective", @objective_limit, index),
         {:ok, expected_result} <-
           child_text(fields, "expected_result", @expected_result_limit, index),
         :ok <- validate_acceptance_criteria_size(expected_result, index) do
      {:ok,
       %{
         "title" => title,
         "objective" => objective,
         "expected_result" => expected_result
       }}
    end
  end

  defp normalize_child(_child, index), do: {:error, {:invalid_child, index}}

  defp normalize_child_keys(child, index) do
    pairs = Enum.map(child, fn {key, value} -> {normalize_key(key), value} end)
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) == length(@allowed_child_keys) and
         Enum.sort(keys) == Enum.sort(@allowed_child_keys) do
      {:ok, Map.new(pairs)}
    else
      {:error, {:invalid_child_keys, index}}
    end
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)

  defp validate_acceptance_criteria_size(expected_result, index) do
    expected_result
    |> then(&AcceptanceCriteria.encode!(%{"summary" => &1}))
    |> String.length()
    |> case do
      length when length <= @acceptance_criteria_limit -> :ok
      _too_large -> {:error, {:encoded_acceptance_criteria_too_large, index}}
    end
  end

  defp child_text(fields, key, limit, index) do
    case Map.fetch(fields, key) do
      {:ok, value} when is_binary(value) ->
        value = String.trim(value)

        if value != "" and String.length(value) <= limit,
          do: {:ok, value},
          else: {:error, {:invalid_child_field, index, String.to_existing_atom(key)}}

      _missing_or_invalid ->
        {:error, {:invalid_child_field, index, String.to_existing_atom(key)}}
    end
  end

  defp validate_unique_children(children) do
    children
    |> Enum.with_index()
    |> Enum.reduce_while({MapSet.new(), MapSet.new()}, fn {child, index}, {titles, objectives} ->
      title = normalize_identity(child["title"])
      objective = normalize_identity(child["objective"])

      if MapSet.member?(titles, title) or MapSet.member?(objectives, objective),
        do: {:halt, {:error, {:duplicate_child, index}}},
        else: {:cont, {MapSet.put(titles, title), MapSet.put(objectives, objective)}}
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      {%MapSet{}, %MapSet{}} -> :ok
    end
  end

  defp normalize_identity(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp source(opts) do
    case Keyword.get(opts, :source, :model) do
      source when source in [:model, :exact_counted] -> {:ok, source}
      source -> {:error, {:invalid_plan_source, source}}
    end
  end

  defp provenance_source(:model), do: "conversation_manager"
  defp provenance_source(:exact_counted), do: "counted_protocol"

  defp build(original_request, children, source) do
    request_sha256 = request_digest(original_request)

    %__MODULE__{
      original_request: original_request,
      original_request_sha256: request_sha256,
      plan_sha256: plan_digest(source, request_sha256, children),
      source: source,
      children: children
    }
  end

  defp counted_children(tasks) do
    tasks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {task, index}, {:ok, acc} when is_binary(task) ->
        objective = String.trim(task)

        if objective == "" or String.length(objective) > @objective_limit do
          {:halt, {:error, {:invalid_counted_task, index}}}
        else
          child = %{
            "title" => bounded_title(objective),
            "objective" => objective,
            "expected_result" => @counted_expected_result
          }

          {:cont, {:ok, [child | acc]}}
        end

      {_task, index}, {:ok, _acc} ->
        {:halt, {:error, {:invalid_counted_task, index}}}
    end)
    |> case do
      {:ok, children} -> {:ok, Enum.reverse(children)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded_title(text) do
    text
    |> String.graphemes()
    |> Enum.take(@title_limit)
    |> IO.iodata_to_binary()
  end

  defp request_digest(text) do
    :sha256
    |> :crypto.hash(text)
    |> Base.encode16(case: :lower)
  end

  defp plan_digest(source, request_sha256, children) do
    fields =
      ["fanout-plan-v1", provenance_source(source), request_sha256] ++
        Enum.flat_map(children, fn child ->
          [child["title"], child["objective"], child["expected_result"]]
        end)

    canonical =
      Enum.map(fields, fn field ->
        [Integer.to_string(byte_size(field)), ?:, field, ?;]
      end)

    :sha256
    |> :crypto.hash(canonical)
    |> Base.encode16(case: :lower)
  end

  defp child_binding(plan_sha256, index, child) do
    %{
      @child_binding_key => %{
        "version" => 1,
        "plan_sha256" => plan_sha256,
        "index" => index,
        "child_sha256" => child_digest(plan_sha256, index, child)
      }
    }
  end

  defp child_digest(plan_sha256, index, child) do
    [
      "fanout-plan-child-v1",
      plan_sha256,
      Integer.to_string(index),
      child["title"],
      child["objective"],
      child["expected_result"]
    ]
    |> Enum.map(fn field -> [Integer.to_string(byte_size(field)), ?:, field, ?;] end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp decode_child_binding(binding) when is_map(binding), do: {:ok, binding}

  defp decode_child_binding(binding) when is_binary(binding) do
    case Jason.decode(binding) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _invalid -> {:error, :invalid_child_binding}
    end
  end

  defp decode_child_binding(_binding), do: {:error, :invalid_child_binding}

  defp binding_keys_valid?(%{@child_binding_key => child_binding} = binding)
       when map_size(binding) == 1 and is_map(child_binding) do
    Map.keys(child_binding) |> Enum.sort() ==
      Enum.sort(~w[version plan_sha256 index child_sha256])
  end

  defp binding_keys_valid?(_binding), do: false
end
