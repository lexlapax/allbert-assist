defmodule AllbertAssist.Jobs do
  @moduledoc """
  Durable local scheduled jobs for v0.13.

  The context owns persistence, schedule normalization, and user-scoped lookup.
  Actual execution is added by the runner/scheduler milestones.
  """

  import Ecto.Query

  alias AllbertAssist.Conversations
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Jobs.Schedule
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings

  @default_status "paused"
  @default_timezone "America/Los_Angeles"
  @default_channel "job"
  @default_list_limit 50
  @known_job_keys [
    :id,
    :name,
    :description,
    :target_type,
    :target,
    :schedule,
    :timezone,
    :status,
    :user_id,
    :operator_id,
    :operator,
    :thread_id,
    :thread_mode,
    :session_id,
    :app_id,
    :channel,
    :next_due_at,
    :last_run_at,
    :blocked_confirmation_id,
    :metadata
  ]

  @known_run_keys [
    :id,
    :job_id,
    :status,
    :trigger,
    :due_at,
    :started_at,
    :finished_at,
    :duration_ms,
    :user_id,
    :operator_id,
    :thread_id,
    :session_id,
    :app_id,
    :input_signal_id,
    :response_signal_id,
    :trace_id,
    :confirmation_id,
    :decision,
    :resource_access,
    :approval_handoff,
    :action_log,
    :error,
    :metadata
  ]

  @type job_result :: {:ok, Job.t()} | {:error, term()}
  @type run_result :: {:ok, Run.t()} | {:error, term()}

  @doc "Create a durable scheduled job."
  @spec create_job(map()) :: job_result()
  def create_job(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_job_attrs(attrs, :create) do
      %Job{}
      |> Job.changeset(attrs)
      |> Repo.insert()
    end
  end

  def create_job(_attrs), do: {:error, :invalid_job_attrs}

  @doc "Fetch a job by opaque id."
  @spec get_job(String.t()) :: job_result()
  def get_job(id) do
    case Repo.get(Job, normalize_optional_string(id)) do
      %Job{} = job -> {:ok, job}
      nil -> {:error, {:job_not_found, id}}
    end
  end

  @doc "Fetch a job only when it belongs to `user_id`."
  @spec get_job(String.t(), String.t()) :: job_result()
  def get_job(user_id, id) do
    user_id = normalize_string(user_id)
    id = normalize_optional_string(id)

    query =
      from job in Job,
        where: job.user_id == ^user_id and job.id == ^id

    case Repo.one(query) do
      %Job{} = job -> {:ok, job}
      nil -> {:error, {:job_not_found, id}}
    end
  end

  @doc "List jobs scoped to a local string user id."
  @spec list_jobs(String.t(), keyword()) :: [Job.t()]
  def list_jobs(user_id, opts \\ []) do
    limit = normalize_limit(Keyword.get(opts, :limit, @default_list_limit))
    statuses = Keyword.get(opts, :status) || Keyword.get(opts, :statuses)
    user_id = normalize_string(user_id)

    Job
    |> where([job], job.user_id == ^user_id)
    |> maybe_filter_statuses(statuses)
    |> order_by([job], asc: job.name, asc: job.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Update a job definition and recompute next due time when needed."
  @spec update_job(Job.t(), map()) :: job_result()
  def update_job(%Job{} = job, attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_job_attrs(Map.merge(Map.from_struct(job), attrs), :update) do
      job
      |> Job.changeset(attrs)
      |> Repo.update()
    end
  end

  def update_job(_job, _attrs), do: {:error, :invalid_job_attrs}

  @doc "Pause a job and clear its next due time."
  @spec pause_job(Job.t() | String.t()) :: job_result()
  def pause_job(%Job{} = job) do
    job
    |> Job.changeset(%{status: "paused", next_due_at: nil})
    |> Repo.update()
  end

  def pause_job(id) when is_binary(id) do
    with {:ok, job} <- get_job(id), do: pause_job(job)
  end

  @doc "Resume a job and recompute its next due time."
  @spec resume_job(Job.t() | String.t()) :: job_result()
  def resume_job(%Job{} = job) do
    with {:ok, next_due_at} <- Schedule.next_due(job.schedule, job.timezone) do
      job
      |> Job.changeset(%{status: "active", next_due_at: next_due_at})
      |> Repo.update()
    end
  end

  def resume_job(id) when is_binary(id) do
    with {:ok, job} <- get_job(id), do: resume_job(job)
  end

  @doc "Create a run record for a job. Execution is handled by later milestones."
  @spec create_run(Job.t(), map()) :: run_result()
  def create_run(job, attrs \\ %{})

  def create_run(%Job{} = job, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> atomize_known_keys(@known_run_keys)
      |> Map.put_new(:id, new_id("run"))
      |> Map.put(:job_id, job.id)
      |> Map.put_new(:status, "queued")
      |> Map.put_new(:trigger, "manual")
      |> Map.put_new(:user_id, job.user_id)
      |> Map.put_new(:operator_id, job.operator_id)
      |> Map.put_new(:thread_id, job.thread_id)
      |> Map.put_new(:session_id, job.session_id)
      |> Map.put_new(:app_id, job.app_id)
      |> Map.put_new(:decision, %{})
      |> Map.put_new(:resource_access, %{})
      |> Map.put_new(:approval_handoff, %{})
      |> Map.put_new(:action_log, %{})
      |> Map.put_new(:error, %{})
      |> Map.put_new(:metadata, %{})

    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  def create_run(_job, _attrs), do: {:error, :invalid_run_attrs}

  @doc "Fetch a run by opaque id."
  @spec get_run(String.t()) :: run_result()
  def get_run(id) do
    case Repo.get(Run, normalize_optional_string(id)) do
      %Run{} = run -> {:ok, run}
      nil -> {:error, {:run_not_found, id}}
    end
  end

  @doc "Update a run record with normalized known fields."
  @spec update_run(Run.t(), map()) :: run_result()
  def update_run(%Run{} = run, attrs) when is_map(attrs) do
    attrs = atomize_known_keys(attrs, @known_run_keys)

    run
    |> Run.changeset(attrs)
    |> Repo.update()
  end

  def update_run(_run, _attrs), do: {:error, :invalid_run_attrs}

  @doc "List runs for a job, newest first."
  @spec list_runs(Job.t(), keyword()) :: [Run.t()]
  def list_runs(%Job{} = job, opts \\ []) do
    limit = normalize_limit(Keyword.get(opts, :limit, @default_list_limit))

    Run
    |> where([run], run.job_id == ^job.id and run.user_id == ^job.user_id)
    |> order_by([run], desc: run.inserted_at, desc: run.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "List active jobs that are due at or before `now`."
  @spec due_jobs(DateTime.t(), pos_integer()) :: [Job.t()]
  def due_jobs(now \\ utc_now(), limit \\ @default_list_limit)

  def due_jobs(%DateTime{} = now, limit) do
    limit = normalize_limit(limit)

    Job
    |> where([job], job.status == "active")
    |> where([job], not is_nil(job.next_due_at) and job.next_due_at <= ^now)
    |> order_by([job], asc: job.next_due_at, asc: job.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Claim one scheduler run for a due job unless it already has an open run."
  @spec claim_due_job(Job.t(), DateTime.t()) :: run_result()
  def claim_due_job(%Job{} = job, now \\ utc_now()) do
    Repo.transaction(fn ->
      case Repo.get(Job, job.id) do
        %Job{} = current_job ->
          claim_current_due_job(current_job, now)

        nil ->
          Repo.rollback({:job_not_found, job.id})
      end
    end)
  end

  @doc "Advance an active job to its next due time after a scheduler run."
  @spec advance_next_due(Job.t()) :: job_result()
  def advance_next_due(%Job{status: "active"} = job) do
    with {:ok, next_due_at} <- Schedule.next_due(job.schedule, job.timezone) do
      job
      |> Job.changeset(%{next_due_at: next_due_at})
      |> Repo.update()
    end
  end

  def advance_next_due(%Job{} = job), do: {:ok, job}

  @doc "Fail stale running runs left behind by a crashed scheduler process."
  @spec fail_stale_running_runs(DateTime.t()) :: {:ok, non_neg_integer()}
  def fail_stale_running_runs(%DateTime{} = stale_before) do
    now = utc_now()

    query =
      from run in Run,
        where:
          run.status == "running" and not is_nil(run.started_at) and
            run.started_at < ^stale_before

    {count, _rows} =
      Repo.update_all(query,
        set: [
          status: "failed",
          finished_at: now,
          error: %{kind: "scheduler_restarted"},
          updated_at: now
        ]
      )

    {:ok, count}
  end

  defp claim_current_due_job(%Job{} = job, now) do
    cond do
      job.status != "active" ->
        Repo.rollback(:not_active)

      is_nil(job.next_due_at) or DateTime.compare(job.next_due_at, now) == :gt ->
        Repo.rollback(:not_due)

      open_run_exists?(job.id) ->
        Repo.rollback(:open_run)

      true ->
        case create_run(job, %{trigger: "scheduler", due_at: job.next_due_at}) do
          {:ok, run} -> run
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp open_run_exists?(job_id) do
    Run
    |> where([run], run.job_id == ^job_id and run.status in ["running", "needs_confirmation"])
    |> select([run], count(run.id))
    |> Repo.one()
    |> Kernel.>(0)
  end

  defp normalize_job_attrs(attrs, mode) do
    attrs = atomize_known_keys(attrs, @known_job_keys)

    with {:ok, {user_id, operator_id}} <- normalize_identity(attrs),
         {:ok, target_type} <- normalize_target_type(Map.get(attrs, :target_type)),
         {:ok, target} <- normalize_target(target_type, Map.get(attrs, :target)),
         {:ok, schedule} <- Schedule.normalize(Map.get(attrs, :schedule) || %{"kind" => "manual"}),
         {:ok, timezone} <- normalize_timezone(Map.get(attrs, :timezone)),
         :ok <- Schedule.validate_timezone(timezone),
         {:ok, status} <- normalize_status(Map.get(attrs, :status), mode),
         {:ok, thread_mode} <- normalize_thread_mode(attrs, target_type),
         :ok <- validate_thread_scope(user_id, attrs, target_type, thread_mode),
         {:ok, next_due_at} <- normalize_next_due(status, schedule, timezone) do
      {:ok,
       attrs
       |> Map.put_new(:id, new_id("job"))
       |> Map.put(:user_id, user_id)
       |> Map.put(:operator_id, operator_id)
       |> Map.put(:target_type, target_type)
       |> Map.put(:target, target)
       |> Map.put(:schedule, schedule)
       |> Map.put(:timezone, timezone)
       |> Map.put(:status, status)
       |> Map.put(:thread_mode, thread_mode)
       |> Map.put_new(:channel, @default_channel)
       |> Map.put_new(:metadata, %{})
       |> Map.put(:next_due_at, next_due_at)}
    end
  end

  defp normalize_identity(attrs) do
    user_id = attrs |> Map.get(:user_id) |> normalize_optional_string()

    operator_id =
      (Map.get(attrs, :operator_id) || Map.get(attrs, :operator)) |> normalize_optional_string()

    cond do
      present?(user_id) and present?(operator_id) and user_id != operator_id ->
        {:error, :identity_conflict}

      present?(user_id) ->
        {:ok, {user_id, user_id}}

      present?(operator_id) ->
        {:ok, {operator_id, operator_id}}

      true ->
        {:ok, {"local", "local"}}
    end
  end

  defp normalize_target_type(value) do
    value = normalize_string(value)

    if value in Job.target_types() do
      {:ok, value}
    else
      {:error, {:invalid_target_type, value}}
    end
  end

  defp normalize_target("runtime_prompt", target) when is_map(target) do
    target = string_key_map(target)
    text = target |> Map.get("text") |> normalize_optional_string()

    if present?(text) do
      {:ok, Map.put(target, "text", text)}
    else
      {:error, {:invalid_target, :missing_text}}
    end
  end

  defp normalize_target("registered_action", target) when is_map(target) do
    target = string_key_map(target)
    action_name = target |> Map.get("action_name") |> normalize_optional_string()
    params = Map.get(target, "params")

    cond do
      not present?(action_name) -> {:error, {:invalid_target, :missing_action_name}}
      not is_map(params) -> {:error, {:invalid_target, :missing_params}}
      true -> {:ok, Map.put(target, "action_name", action_name)}
    end
  end

  defp normalize_target(_target_type, _target), do: {:error, {:invalid_target, :not_a_map}}

  defp normalize_timezone(nil), do: setting("jobs.timezone", @default_timezone)
  defp normalize_timezone(value), do: {:ok, normalize_string(value)}

  defp normalize_status(nil, _mode), do: setting("jobs.default_state", @default_status)

  defp normalize_status(value, _mode) do
    value = normalize_string(value)

    if value in Job.statuses() do
      {:ok, value}
    else
      {:error, {:invalid_status, value}}
    end
  end

  defp normalize_thread_mode(_attrs, "registered_action"), do: {:ok, "recent_general"}

  defp normalize_thread_mode(attrs, "runtime_prompt") do
    value = attrs |> Map.get(:thread_mode) |> normalize_optional_string()

    cond do
      present?(value) and value in Job.thread_modes() ->
        {:ok, value}

      present?(value) ->
        {:error, {:invalid_thread_mode, value}}

      present?(Map.get(attrs, :thread_id)) ->
        {:ok, "origin_thread"}

      true ->
        {:ok, "recent_general"}
    end
  end

  defp validate_thread_scope(user_id, attrs, "runtime_prompt", "origin_thread") do
    thread_id = attrs |> Map.get(:thread_id) |> normalize_optional_string()

    if present?(thread_id) do
      case Conversations.get_thread(user_id, thread_id) do
        {:ok, _thread} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :thread_id_required}
    end
  end

  defp validate_thread_scope(_user_id, _attrs, _target_type, _thread_mode), do: :ok

  defp normalize_next_due("active", schedule, timezone) do
    Schedule.next_due(schedule, timezone)
  end

  defp normalize_next_due(_status, _schedule, _timezone), do: {:ok, nil}

  defp maybe_filter_statuses(query, nil), do: query

  defp maybe_filter_statuses(query, statuses) do
    statuses =
      statuses
      |> List.wrap()
      |> Enum.map(&normalize_string/1)
      |> Enum.filter(&(&1 in Job.statuses()))

    case statuses do
      [] -> query
      statuses -> where(query, [job], job.status in ^statuses)
    end
  end

  defp setting(key, fallback) do
    case Settings.get(key) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:ok, fallback}
    end
  end

  defp atomize_known_keys(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      string_key = Atom.to_string(key)

      case {Map.fetch(acc, key), Map.fetch(acc, string_key)} do
        {:error, {:ok, value}} -> Map.put(acc, key, value)
        _other -> acc
      end
    end)
  end

  defp string_key_map(map) do
    Map.new(map, fn {key, value} -> {normalize_string(key), value} end)
  end

  defp new_id(prefix), do: "#{prefix}_#{Ecto.UUID.generate()}"

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) do
    value
    |> normalize_string()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(value) when is_atom(value), do: value |> Atom.to_string() |> String.trim()
  defp normalize_string(nil), do: ""
  defp normalize_string(value), do: value |> to_string() |> String.trim()

  defp normalize_limit(value) when is_integer(value) and value > 0, do: min(value, 100)

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> normalize_limit(limit)
      _other -> @default_list_limit
    end
  end

  defp normalize_limit(_value), do: @default_list_limit

  defp present?(value), do: value not in [nil, ""]

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
