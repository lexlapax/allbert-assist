defmodule AllbertAssist.Jobs.Managed do
  @moduledoc """
  Reconciles the small, fixed set of domain-managed jobs into ordinary Jobs rows.

  This is deliberately not a scheduler or projection coordinator. Jobs keeps
  due-state, overlap admission, execution, pause semantics, and run history;
  this module owns only reserved identity, invariant targets, feature gating,
  dirty coalescing, and completion reconciliation.
  """

  import Ecto.Query

  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Jobs.Schedule
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings

  @managed_by "jobs.managed"
  @managed_schema 1
  @managed_spec_version 1
  @kick_coalesce_seconds 60
  @default_timezone "America/Los_Angeles"

  @specs [
    %{
      identity: "memory-index-rebuild",
      description: "Build, verify, and promote the derived Memory projection.",
      action: "rebuild_memory_projection",
      schedule: :memory_review_cadence,
      feature: :memory_projection
    },
    %{
      identity: "memory-consolidation",
      description: "Collect bounded conversation evidence into inert Memory proposals.",
      action: "consolidate_memory",
      schedule: %{"kind" => "weekly", "weekday" => "sunday", "at" => "03:00"},
      feature: :memory_consolidation
    },
    %{
      identity: "search-index",
      description: "Ingest dirty conversation changes and run bounded hourly repair.",
      action: "ingest_search_index",
      schedule: %{"kind" => "cron", "expression" => "0 * * * *"},
      feature: :search
    },
    %{
      identity: "search-maintain",
      description: "Verify and maintain the current Search projection generation.",
      action: "maintain_search_index",
      schedule: %{"kind" => "weekly", "weekday" => "sunday", "at" => "04:00"},
      feature: :search
    },
    %{
      identity: "search-rebuild",
      description: "Build, verify, and promote a complete Search projection generation.",
      action: "rebuild_search_index",
      schedule: %{"kind" => "manual"},
      feature: :search
    }
  ]

  @type reconcile_result :: %{
          managed_identity: String.t(),
          outcome: :created | :current | :adopted | :updated | :managed_name_conflict,
          job_id: String.t() | nil,
          degraded?: boolean(),
          reason: term() | nil
        }

  @doc "Return the five frozen v1.3 managed specifications."
  def specs do
    Enum.map(@specs, fn spec ->
      spec
      |> Map.put(:managed_spec_digest, spec_digest(spec))
      |> Map.put(:managed_spec_version, @managed_spec_version)
    end)
  end

  @doc "Reconcile exactly one ordinary Jobs row per reserved identity."
  @spec reconcile(String.t()) :: {:ok, [reconcile_result()]} | {:error, term()}
  def reconcile(user_id \\ "local") when is_binary(user_id) do
    user_id = String.trim(user_id)

    if user_id == "" do
      {:error, :invalid_managed_user}
    else
      {:ok, Enum.map(@specs, &reconcile_spec(user_id, &1))}
    end
  end

  @doc "Reconcile one named managed specification without creating unrelated entries."
  @spec reconcile_identity(String.t(), String.t()) ::
          {:ok, reconcile_result()} | {:error, term()}
  def reconcile_identity(identity, user_id \\ "local")
      when is_binary(identity) and is_binary(user_id) do
    user_id = String.trim(user_id)

    with false <- user_id == "",
         %{} = spec <- spec_for(identity) do
      {:ok, reconcile_spec(user_id, spec)}
    else
      true -> {:error, :invalid_managed_user}
      nil -> {:error, {:unknown_managed_identity, identity}}
    end
  end

  @doc "Coalesce dirty work onto one existing managed entry without creating a run."
  @spec kick(String.t(), String.t() | map()) :: {:ok, map()} | {:error, term()}
  def kick(identity, user_or_context \\ "local") when is_binary(identity) do
    user_id = managed_user(user_or_context)

    Repo.transaction(
      fn -> kick_managed_job(user_id, identity) end,
      mode: :immediate
    )
  end

  defp kick_managed_job(user_id, identity) do
    case managed_job(user_id, identity) do
      nil -> Repo.rollback({:managed_job_not_found, identity})
      %Job{} = job -> apply_managed_kick(job, identity)
    end
  end

  defp apply_managed_kick(job, identity) do
    with :ok <- invariant_job(job, spec_for(identity)),
         {:ok, updated} <- apply_kick(job) do
      %{
        outcome: :kicked,
        job_id: updated.id,
        managed_identity: identity,
        dirty_seq: metadata_integer(updated.metadata, "dirty_seq"),
        status: updated.status,
        due_at: updated.next_due_at
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc "Complete managed due/dirty state without overwriting a racing kick or pause."
  @spec complete_run(Job.t(), Run.t(), map() | nil) :: {:ok, Job.t()} | {:error, term()}
  def complete_run(job, run, response \\ nil)

  def complete_run(%Job{} = job, %Run{} = run, response) do
    complete_managed_run(managed?(job), job, run, response)
  end

  def complete_run(job, _run, _response), do: {:ok, job}

  defp complete_managed_run(false, job, _run, _response), do: {:ok, job}

  defp complete_managed_run(true, job, run, response) do
    Repo.transaction(
      fn -> reconcile_current_completion(job.id, run, response) end,
      mode: :immediate
    )
  end

  defp reconcile_current_completion(job_id, run, response) do
    current = Repo.get!(Job, job_id)

    with :ok <- invariant_job(current, spec_for(current.name)),
         {:ok, updated} <- reconcile_completion(current, run, response) do
      updated
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc "Return true only for a structurally owned Jobs.Managed row."
  def managed?(%Job{metadata: metadata}) when is_map(metadata),
    do: metadata_value(metadata, "managed_by") == @managed_by

  def managed?(_job), do: false

  @doc "Reject ordinary admission only when a managed feature is effectively disabled."
  def admission_allowed?(%Job{} = job) do
    if managed?(job) do
      with :ok <- invariant_job(job, spec_for(job.name)) do
        feature_admission(job.metadata)
      end
    else
      :ok
    end
  end

  def admission_allowed?(_job), do: :ok

  defp feature_admission(metadata) do
    if metadata_value(metadata, "feature_enabled") == true,
      do: :ok,
      else: {:error, :managed_feature_disabled}
  end

  @doc "Compute resume due-state while preserving a dirty managed entry."
  def resume_due(%Job{} = job, scheduled_due) do
    cond do
      managed?(job) and metadata_value(job.metadata, "feature_enabled") != true ->
        nil

      managed?(job) and dirty?(job) ->
        earliest_due(job.next_due_at, kick_due_at()) || scheduled_due

      true ->
        scheduled_due
    end
  end

  defp reconcile_spec(user_id, spec) do
    case managed_job(user_id, spec.identity) do
      nil -> create_spec(user_id, spec)
      %Job{} = job -> reconcile_existing(job, spec)
    end
  rescue
    exception -> diagnostic(spec, :managed_name_conflict, nil, Exception.message(exception))
  end

  defp create_spec(user_id, spec) do
    enabled? = feature_enabled?(spec.feature)

    attrs = %{
      name: spec.identity,
      description: spec.description,
      target_type: "registered_action",
      target: target(spec),
      schedule: schedule(spec.schedule),
      timezone: @default_timezone,
      status: "active",
      user_id: user_id,
      operator_id: user_id,
      metadata: managed_metadata(spec, enabled?)
    }

    with {:ok, job} <- Jobs.create_job(attrs),
         {:ok, effective} <- apply_feature_state(job, enabled?) do
      diagnostic(spec, :created, effective.id, nil)
    else
      {:error, reason} -> diagnostic(spec, :managed_name_conflict, nil, reason)
    end
  end

  defp reconcile_existing(job, spec) do
    cond do
      legacy_adoptable?(job, spec) -> adopt_legacy(job, spec)
      not managed?(job) -> diagnostic(spec, :managed_name_conflict, job.id, :reserved_name_owned)
      true -> reconcile_owned(job, spec)
    end
  end

  defp reconcile_owned(job, spec) do
    with :ok <- invariant_job(job, spec),
         enabled? <- feature_enabled?(spec.feature),
         {:ok, updated} <- apply_feature_state(job, enabled?) do
      outcome = if updated == job, do: :current, else: :updated
      diagnostic(spec, outcome, updated.id, nil)
    else
      {:error, reason} -> diagnostic(spec, :managed_name_conflict, job.id, reason)
    end
  end

  defp adopt_legacy(job, spec) do
    enabled? = feature_enabled?(spec.feature)

    attrs = %{
      description: spec.description,
      target: target(spec),
      metadata: Map.merge(string_key_map(job.metadata || %{}), managed_metadata(spec, enabled?))
    }

    with {:ok, adopted} <- job |> Job.changeset(attrs) |> Repo.update(),
         {:ok, effective} <- apply_feature_state(adopted, enabled?) do
      diagnostic(spec, :adopted, effective.id, nil)
    else
      {:error, reason} -> diagnostic(spec, :managed_name_conflict, job.id, reason)
    end
  end

  defp apply_feature_state(job, enabled?) do
    metadata =
      job.metadata
      |> string_key_map()
      |> Map.put("feature_enabled", enabled?)

    next_due_at = effective_due(job, enabled?, metadata)

    job
    |> Job.changeset(%{metadata: metadata, next_due_at: next_due_at})
    |> Repo.update()
  end

  defp effective_due(_job, false, _metadata), do: nil
  defp effective_due(%Job{status: status}, true, _metadata) when status != "active", do: nil

  defp effective_due(job, true, metadata) do
    cond do
      pending_dirty?(metadata) -> earliest_due(job.next_due_at, kick_due_at())
      job.next_due_at -> job.next_due_at
      true -> next_schedule_due(job)
    end
  end

  defp apply_kick(job) do
    metadata = string_key_map(job.metadata || %{})
    dirty_seq = metadata_integer(metadata, "dirty_seq") + 1
    metadata = Map.put(metadata, "dirty_seq", dirty_seq)
    enabled? = metadata_value(metadata, "feature_enabled") == true
    due_at = effective_due(job, enabled?, metadata)

    job
    |> Job.changeset(%{metadata: metadata, next_due_at: due_at})
    |> Repo.update()
  end

  defp reconcile_completion(job, run, response) do
    metadata = string_key_map(job.metadata || %{})
    dirty_seq = metadata_integer(metadata, "dirty_seq")
    clean_seq = metadata_integer(metadata, "clean_dirty_seq")
    claimed_seq = metadata_integer(run.metadata || %{}, "claimed_dirty_seq")

    metadata =
      if dirty_seq == claimed_seq do
        Map.put(metadata, "clean_dirty_seq", max(clean_seq, claimed_seq))
      else
        metadata
      end

    due_at = completion_due(job, metadata, response)

    job
    |> Job.changeset(%{metadata: metadata, next_due_at: due_at})
    |> Repo.update()
  end

  defp completion_due(%Job{status: status}, _metadata, _response) when status != "active", do: nil

  defp completion_due(job, metadata, response) do
    if metadata_value(metadata, "feature_enabled") == true do
      enabled_completion_due(job, metadata, response)
    else
      nil
    end
  end

  defp enabled_completion_due(job, metadata, response) do
    continuation = continuation_due_at(response)
    scheduled = next_schedule_due(job)

    if pending_dirty?(metadata) do
      [job.next_due_at, continuation, kick_due_at(), scheduled]
      |> Enum.reject(&is_nil/1)
      |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
    else
      earliest_due(continuation, scheduled)
    end
  end

  defp next_schedule_due(job) do
    case Schedule.next_due(job.schedule, job.timezone) do
      {:ok, due_at} -> due_at
      {:error, _reason} -> nil
    end
  end

  defp continuation_due_at(response) when is_map(response) do
    value = Map.get(response, :continuation_due_at, Map.get(response, "continuation_due_at"))

    case value do
      %DateTime{} = datetime -> datetime
      value when is_binary(value) -> parse_datetime(value)
      _other -> nil
    end
  end

  defp continuation_due_at(_response), do: nil

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp legacy_adoptable?(job, %{identity: "memory-index-rebuild"}) do
    metadata = job.metadata || %{}
    target = string_key_map(job.target || %{})

    job.user_id == "local" and job.operator_id == "local" and
      metadata_value(metadata, "template_name") == "memory-index-rebuild" and
      metadata_value(metadata, "managed_by") in [nil, "memory.review_cadence"] and
      job.target_type == "registered_action" and
      target["params"] == %{} and
      target["action_name"] in ["compile_memory_index", "rebuild_memory_projection"]
  end

  defp legacy_adoptable?(_job, _spec), do: false

  defp invariant_job(job, nil), do: {:error, {:unknown_managed_identity, job.name}}

  defp invariant_job(job, spec) do
    metadata = job.metadata || %{}

    checks = [
      job.name == spec.identity,
      job.target_type == "registered_action",
      string_key_map(job.target || %{}) == target(spec),
      job.user_id == job.operator_id,
      metadata_value(metadata, "managed_by") == @managed_by,
      metadata_integer(metadata, "managed_schema") == @managed_schema,
      metadata_value(metadata, "managed_identity") == spec.identity,
      metadata_integer(metadata, "managed_spec_version") == @managed_spec_version,
      metadata_value(metadata, "managed_spec_digest") == spec_digest(spec)
    ]

    if Enum.all?(checks) do
      :ok
    else
      {:error, :managed_invariant_drift}
    end
  end

  defp managed_metadata(spec, enabled?) do
    %{
      "managed_by" => @managed_by,
      "managed_schema" => @managed_schema,
      "managed_identity" => spec.identity,
      "managed_spec_version" => @managed_spec_version,
      "managed_spec_digest" => spec_digest(spec),
      "dirty_seq" => 0,
      "clean_dirty_seq" => 0,
      "feature_enabled" => enabled?
    }
  end

  defp spec_digest(spec) do
    frozen =
      {spec.identity, spec.action, [], spec.feature, @managed_schema, @managed_spec_version}

    "sha256:" <>
      (:crypto.hash(:sha256, :erlang.term_to_binary(frozen)) |> Base.encode16(case: :lower))
  end

  defp target(spec), do: %{"action_name" => spec.action, "params" => %{}}

  defp schedule(:memory_review_cadence) do
    case setting("memory.review_cadence", "manual") do
      "daily" -> %{"kind" => "daily", "at" => "03:00"}
      "weekly" -> %{"kind" => "weekly", "weekday" => "sunday", "at" => "03:00"}
      _other -> %{"kind" => "manual"}
    end
  end

  defp schedule(schedule), do: schedule

  defp feature_enabled?(:search), do: setting("search.enabled", true)
  defp feature_enabled?(:memory_projection), do: true

  defp feature_enabled?(:memory_consolidation) do
    setting("memory.consolidation.enabled", false) and
      setting("memory.collection.origin_grants", []) != []
  end

  defp setting(key, fallback) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> fallback
    end
  end

  defp spec_for(identity), do: Enum.find(@specs, &(&1.identity == identity))

  defp managed_job(user_id, identity) do
    Repo.one(
      from(job in Job,
        where: job.user_id == ^user_id and job.name == ^identity,
        limit: 1
      )
    )
  end

  defp managed_user(value) when is_binary(value), do: String.trim(value)

  defp managed_user(context) when is_map(context) do
    request = Map.get(context, :request, Map.get(context, "request", context))

    Map.get(request, :user_id, Map.get(request, "user_id", "local"))
    |> to_string()
    |> String.trim()
  end

  defp managed_user(_value), do: "local"

  defp dirty?(job), do: pending_dirty?(string_key_map(job.metadata || %{}))

  defp pending_dirty?(metadata) do
    metadata_integer(metadata, "dirty_seq") > metadata_integer(metadata, "clean_dirty_seq")
  end

  defp metadata_integer(metadata, key) do
    case metadata_value(metadata, key) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key, Map.get(metadata, known_metadata_atom(key)))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp known_metadata_atom("managed_by"), do: :managed_by
  defp known_metadata_atom("managed_schema"), do: :managed_schema
  defp known_metadata_atom("managed_identity"), do: :managed_identity
  defp known_metadata_atom("managed_spec_version"), do: :managed_spec_version
  defp known_metadata_atom("managed_spec_digest"), do: :managed_spec_digest
  defp known_metadata_atom("dirty_seq"), do: :dirty_seq
  defp known_metadata_atom("clean_dirty_seq"), do: :clean_dirty_seq
  defp known_metadata_atom("feature_enabled"), do: :feature_enabled
  defp known_metadata_atom(_key), do: nil

  defp string_key_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp string_key_map(_map), do: %{}

  defp kick_due_at,
    do:
      DateTime.utc_now()
      |> DateTime.add(@kick_coalesce_seconds, :second)
      |> DateTime.truncate(:microsecond)

  defp earliest_due(nil, right), do: right
  defp earliest_due(left, nil), do: left

  defp earliest_due(left, right) do
    if DateTime.compare(left, right) in [:lt, :eq], do: left, else: right
  end

  defp diagnostic(spec, outcome, job_id, reason) do
    %{
      managed_identity: spec.identity,
      outcome: outcome,
      job_id: job_id,
      degraded?: outcome == :managed_name_conflict,
      reason: reason
    }
  end
end
