defmodule AllbertAssist.Objectives do
  @moduledoc """
  Durable objective runtime context.

  v0.24 keeps SQLite authoritative. JidoBacked agent state is a rebuildable
  projection over this context.
  """

  import Ecto.Query

  alias AllbertAssist.Objectives.{AcceptanceCriteria, Event, Objective, Step}
  alias AllbertAssist.Repo
  alias AllbertAssist.Security.Redactor

  @active_statuses ~w[open running blocked]
  @default_list_limit 50
  @rehydrate_window_seconds 60 * 60
  @known_keys MapSet.new([
                "acceptance_criteria",
                "action_params",
                "active_app",
                "candidate_action",
                "completed_at",
                "constraints",
                "current_step_id",
                "delegate_agent_id",
                "id",
                "kind",
                "last_observation_summary",
                "loop_count",
                "objective",
                "objective_id",
                "parent_objective_id",
                "parent_step_id",
                "progress_summary",
                "proposer_hint",
                "provider",
                "recorded_at",
                "resource_access",
                "result_summary",
                "session_id",
                "source_intent",
                "source_thread_id",
                "stage",
                "status",
                "step_id",
                "summary",
                "title",
                "trace_id",
                "user_id",
                "payload"
              ])

  @type objective_result :: {:ok, Objective.t()} | {:error, term()}
  @type step_result :: {:ok, Step.t()} | {:error, term()}
  @type event_result :: {:ok, Event.t()} | {:error, term()}

  @doc "Generate an opaque objective-system id."
  @spec new_id(String.t()) :: String.t()
  def new_id(prefix) when is_binary(prefix), do: prefix <> "_" <> Ecto.UUID.generate()

  @doc "Create an objective."
  @spec create_objective(map()) :: objective_result()
  def create_objective(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> atomize_known()
      |> Map.put_new(:id, new_id("obj"))
      |> Map.put_new(:status, "open")
      |> Map.update(:acceptance_criteria, nil, &encode_jsonish/1)
      |> Map.update(:proposer_hint, nil, &encode_jsonish/1)

    %Objective{}
    |> Objective.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an objective."
  @spec update_objective(Objective.t(), map()) :: objective_result()
  def update_objective(%Objective{} = objective, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> atomize_known()
      |> Map.update(:acceptance_criteria, nil, &encode_jsonish/1)
      |> Map.update(:proposer_hint, nil, &encode_jsonish/1)

    objective
    |> Objective.changeset(attrs)
    |> Repo.update()
  end

  @doc "Fetch an objective by id."
  @spec get_objective(String.t()) :: objective_result()
  def get_objective(id) when is_binary(id) do
    case Repo.get(Objective, id) do
      %Objective{} = objective -> {:ok, objective}
      nil -> {:error, {:objective_not_found, id}}
    end
  end

  @doc "Fetch an objective scoped to a user id."
  @spec get_objective(String.t(), String.t()) :: objective_result()
  def get_objective(user_id, id) when is_binary(user_id) and is_binary(id) do
    query =
      from objective in Objective, where: objective.user_id == ^user_id and objective.id == ^id

    case Repo.one(query) do
      %Objective{} = objective -> {:ok, objective}
      nil -> {:error, :not_found}
    end
  end

  @doc "List objectives scoped to a user id."
  @spec list_objectives(String.t(), keyword()) :: [Objective.t()]
  def list_objectives(user_id, opts \\ []) when is_binary(user_id) and is_list(opts) do
    limit = normalize_limit(Keyword.get(opts, :limit), @default_list_limit, 100)
    statuses = Keyword.get(opts, :status) || Keyword.get(opts, :statuses)
    active_app = Keyword.get(opts, :active_app)
    source_thread_id = Keyword.get(opts, :source_thread_id)

    Objective
    |> where([objective], objective.user_id == ^user_id)
    |> maybe_filter_statuses(statuses)
    |> maybe_filter(:active_app, active_app)
    |> maybe_filter(:source_thread_id, source_thread_id)
    |> order_by([objective], desc: objective.updated_at, desc: objective.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Return active objectives eligible for JidoBacked rehydration."
  @spec active_objectives(keyword()) :: [Objective.t()]
  def active_objectives(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    window_seconds = Keyword.get(opts, :window_seconds, @rehydrate_window_seconds)
    cutoff = DateTime.add(now, -window_seconds, :second)

    Objective
    |> where([objective], objective.status in ^@active_statuses)
    |> where([objective], objective.updated_at >= ^cutoff)
    |> order_by([objective], asc: objective.updated_at)
    |> Repo.all()
  end

  @doc "Mark stale active objectives abandoned and return the count."
  @spec abandon_stale_objectives(keyword()) :: {:ok, non_neg_integer()}
  def abandon_stale_objectives(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    window_seconds = Keyword.get(opts, :window_seconds, @rehydrate_window_seconds)
    cutoff = DateTime.add(now, -window_seconds, :second)

    {count, _} =
      Objective
      |> where([objective], objective.status in ^@active_statuses)
      |> where([objective], objective.updated_at < ^cutoff)
      |> Repo.update_all(set: [status: "abandoned", updated_at: now])

    {:ok, count}
  end

  @doc "Create a step."
  @spec create_step(map()) :: step_result()
  def create_step(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> atomize_known()
      |> Map.put_new(:id, new_id("step"))
      |> Map.put_new(:status, "proposed")
      |> normalize_step_fields()
      |> Map.update(:action_params, nil, &encode_jsonish/1)
      |> Map.update(:resource_access, nil, &encode_jsonish/1)

    %Step{}
    |> Step.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update a step."
  @spec update_step(Step.t(), map()) :: step_result()
  def update_step(%Step{} = step, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> atomize_known()
      |> normalize_step_fields()
      |> Map.update(:action_params, nil, &encode_jsonish/1)
      |> Map.update(:resource_access, nil, &encode_jsonish/1)

    step
    |> Step.changeset(attrs)
    |> Repo.update()
  end

  @doc "Transition a step to a new status."
  @spec transition_step(Step.t(), String.t() | atom(), map()) :: step_result()
  def transition_step(%Step{} = step, status, attrs \\ %{}) do
    update_step(step, Map.merge(attrs, %{status: normalize_string(status)}))
  end

  @doc "List steps for an objective."
  @spec list_steps(String.t()) :: [Step.t()]
  def list_steps(objective_id) when is_binary(objective_id) do
    Step
    |> where([step], step.objective_id == ^objective_id)
    |> order_by([step], asc: step.inserted_at, asc: step.id)
    |> Repo.all()
  end

  @doc "Create an event."
  @spec create_event(map()) :: event_result()
  def create_event(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> atomize_known()
      |> Map.put_new(:id, new_id("evt"))
      |> Map.put_new(:recorded_at, DateTime.utc_now())
      |> Map.update(:payload, nil, &encode_event_payload/1)

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  @doc "List recent events for an objective."
  @spec list_events(String.t(), keyword()) :: [Event.t()]
  def list_events(objective_id, opts \\ []) do
    limit = normalize_limit(Keyword.get(opts, :limit), 50, 200)

    Event
    |> where([event], event.objective_id == ^objective_id)
    |> order_by([event], desc: event.recorded_at, desc: event.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Return the decoded acceptance criteria for an objective."
  @spec acceptance_criteria(Objective.t()) :: {:ok, map() | nil} | {:error, term()}
  def acceptance_criteria(%Objective{acceptance_criteria: criteria}) do
    AcceptanceCriteria.decode(criteria)
  end

  @doc "Return a bounded map safe for traces and signals."
  @spec objective_summary(Objective.t()) :: map()
  def objective_summary(%Objective{} = objective) do
    %{
      id: objective.id,
      user_id: objective.user_id,
      source_thread_id: objective.source_thread_id,
      active_app: objective.active_app,
      status: objective.status,
      title: objective.title,
      current_step_id: objective.current_step_id,
      loop_count: objective.loop_count
    }
    |> Redactor.redact()
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, field, value), do: where(query, [row], field(row, ^field) == ^value)

  defp maybe_filter_statuses(query, nil), do: query

  defp maybe_filter_statuses(query, statuses) do
    statuses = statuses |> List.wrap() |> Enum.map(&normalize_string/1)
    where(query, [objective], objective.status in ^statuses)
  end

  defp normalize_limit(nil, default, _max), do: default

  defp normalize_limit(limit, _default, max) when is_integer(limit),
    do: limit |> max(1) |> min(max)

  defp normalize_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> normalize_limit(parsed, default, max)
      _ -> default
    end
  end

  defp normalize_limit(_limit, default, _max), do: default

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: value

  defp encode_jsonish(nil), do: nil
  defp encode_jsonish(value) when is_binary(value), do: value
  defp encode_jsonish(value), do: Jason.encode!(Redactor.redact(value))

  defp encode_event_payload(nil), do: nil
  defp encode_event_payload(value) when is_binary(value), do: value
  defp encode_event_payload(value), do: Jason.encode!(Redactor.redact(value))

  defp normalize_step_fields(attrs) do
    attrs
    |> update_if_present(:kind, &normalize_string/1)
    |> update_if_present(:status, &normalize_string/1)
    |> update_if_present(:stage, fn
      stage when is_atom(stage) -> Atom.to_string(stage)
      stage -> stage
    end)
  end

  defp update_if_present(attrs, key, fun) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(attrs, key, fun.(value))
      :error -> attrs
    end
  end

  defp atomize_known(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), value)
    end)
  end

  defp normalize_key(key) when is_binary(key) do
    if MapSet.member?(@known_keys, key), do: String.to_existing_atom(key), else: key
  end

  defp normalize_key(key), do: key
end
