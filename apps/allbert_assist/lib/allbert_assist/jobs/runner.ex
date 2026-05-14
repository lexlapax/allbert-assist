defmodule AllbertAssist.Jobs.Runner do
  @moduledoc """
  Manual and scheduler execution boundary for scheduled jobs.

  The runner does not execute job targets directly. Runtime prompt jobs flow
  through `AllbertAssist.Runtime.submit_user_input/1`; registered action jobs
  flow through `AllbertAssist.Actions.Runner.run/3`.
  """

  require Logger

  alias AllbertAssist.Actions
  alias AllbertAssist.Conversations
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Security.Redactor

  @type run_result :: %{
          job: Job.t(),
          run: Run.t(),
          response: map() | nil
        }

  @doc "Create and execute a manual run for a job."
  @spec run_now(Job.t() | String.t(), keyword() | map()) :: {:ok, run_result()} | {:error, term()}
  def run_now(job_or_id, opts \\ []) do
    opts = to_map(opts)

    with {:ok, job} <- resolve_job(job_or_id),
         {:ok, run} <- Jobs.create_run(job, %{trigger: "manual", due_at: Map.get(opts, :due_at)}) do
      execute_run(job, run, opts)
    end
  end

  @doc "Execute an already-created run through the job target boundary."
  @spec execute_run(Job.t(), Run.t(), keyword() | map()) :: {:ok, run_result()} | {:error, term()}
  def execute_run(job, run, opts \\ [])

  def execute_run(%Job{} = job, %Run{} = run, opts) do
    opts = to_map(opts)
    started_at = utc_now()
    started_monotonic = System.monotonic_time(:millisecond)

    with {:ok, running_run} <-
           Jobs.update_run(run, %{status: "running", started_at: started_at}) do
      job
      |> execute_target(running_run, opts)
      |> finish_run(job, running_run, started_at, started_monotonic)
    end
  end

  def execute_run(_job, _run, _opts), do: {:error, :invalid_run}

  defp resolve_job(%Job{} = job), do: {:ok, job}
  defp resolve_job(id) when is_binary(id), do: Jobs.get_job(id)
  defp resolve_job(_job), do: {:error, :invalid_job}

  defp execute_target(%Job{target_type: "runtime_prompt"} = job, run, opts) do
    with :ok <- validate_runtime_thread(job),
         {:ok, request} <- runtime_request(job, run, opts) do
      Runtime.submit_user_input(request)
    end
  end

  defp execute_target(%Job{target_type: "registered_action"} = job, run, _opts) do
    target = job.target || %{}
    action_name = Map.get(target, "action_name")
    params = target |> Map.get("params", %{}) |> atomize_existing_keys()

    Actions.Runner.run(action_name, params, action_context(job, run))
  end

  defp execute_target(%Job{target_type: target_type}, _run, _opts) do
    {:error, {:unsupported_job_target_type, target_type}}
  end

  defp runtime_request(job, run, opts) do
    target = job.target || %{}

    request =
      %{
        text: Map.get(target, "text"),
        channel: :job,
        user_id: job.user_id,
        operator_id: job.operator_id,
        session_id: job.session_id,
        metadata: runtime_metadata(job, run)
      }
      |> maybe_put_timeout(opts)
      |> put_thread_request(job)

    {:ok, request}
  end

  defp validate_runtime_thread(%Job{thread_mode: "origin_thread", thread_id: thread_id} = job) do
    case Conversations.get_thread(job.user_id, thread_id) do
      {:ok, _thread} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_runtime_thread(_job), do: :ok

  defp put_thread_request(request, %Job{thread_mode: "origin_thread", thread_id: thread_id}) do
    Map.put(request, :thread_id, thread_id)
  end

  defp put_thread_request(request, %Job{thread_mode: "new_thread_per_run"}) do
    Map.put(request, :new_thread, true)
  end

  defp put_thread_request(request, _job), do: request

  defp maybe_put_timeout(request, %{timeout_ms: timeout_ms}) when is_integer(timeout_ms) do
    Map.put(request, :timeout_ms, timeout_ms)
  end

  defp maybe_put_timeout(request, _opts), do: request

  defp action_context(job, run) do
    %{
      request: %{
        channel: :job,
        job_id: job.id,
        run_id: run.id,
        user_id: job.user_id,
        operator_id: job.operator_id,
        thread_id: job.thread_id,
        session_id: job.session_id,
        app_id: job.app_id
      },
      channel: :job,
      job_id: job.id,
      run_id: run.id,
      user_id: job.user_id,
      operator_id: job.operator_id,
      thread_id: job.thread_id,
      session_id: job.session_id,
      app_id: job.app_id,
      agent: __MODULE__
    }
  end

  defp runtime_metadata(job, run) do
    %{
      job_id: job.id,
      run_id: run.id,
      job_name: job.name,
      app_id: job.app_id,
      trigger: run.trigger
    }
  end

  defp finish_run({:ok, response}, job, run, _started_at, started_monotonic) do
    duration_ms = System.monotonic_time(:millisecond) - started_monotonic

    attrs =
      response
      |> success_run_attrs(duration_ms, run)
      |> Map.put(:finished_at, utc_now())

    with {:ok, finished_run} <- Jobs.update_run(run, attrs),
         {:ok, updated_job} <- update_job_after_run(job, finished_run) do
      {:ok, %{job: updated_job, run: finished_run, response: response}}
    end
  end

  defp finish_run({:error, reason}, job, run, _started_at, started_monotonic) do
    duration_ms = System.monotonic_time(:millisecond) - started_monotonic

    attrs = %{
      status: "failed",
      finished_at: utc_now(),
      duration_ms: duration_ms,
      error: Redactor.redact(%{reason: inspect(reason)})
    }

    Logger.warning(
      "scheduled job run failed job_id=#{job.id} run_id=#{run.id} reason=#{inspect(reason)}"
    )

    with {:ok, failed_run} <- Jobs.update_run(run, attrs),
         {:ok, updated_job} <- update_job_after_run(job, failed_run) do
      {:ok, %{job: updated_job, run: failed_run, response: nil}}
    end
  end

  defp success_run_attrs(response, duration_ms, run) do
    %{
      status: run_status(response),
      duration_ms: duration_ms,
      thread_id: response_field(response, :thread_id) || run.thread_id,
      input_signal_id: input_signal_id(response),
      response_signal_id: response_signal_id(response),
      trace_id: response_field(response, :trace_id),
      confirmation_id: confirmation_id(response),
      decision: redacted_map(response_field(response, :decision)),
      resource_access: resource_access_payload(response_field(response, :resource_access)),
      approval_handoff: redacted_map(response_field(response, :approval_handoff)),
      action_log: action_log(response),
      error: response_error(response)
    }
  end

  defp run_status(response) do
    case normalized_status(response_field(response, :status)) do
      "needs_confirmation" -> "needs_confirmation"
      "completed" -> "completed"
      "ok" -> "completed"
      "denied" -> "failed"
      "error" -> "failed"
      _other -> "completed"
    end
  end

  defp normalized_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalized_status(status) when is_binary(status), do: status
  defp normalized_status(status), do: to_string(status)

  defp input_signal_id(response) do
    response_field(response, :input_signal_id) ||
      get_in(response, [:runner_metadata, :requested_signal_id]) ||
      get_in(response, ["runner_metadata", "requested_signal_id"])
  end

  defp response_signal_id(response) do
    response_field(response, :signal_id) ||
      response_field(response, :response_signal_id) ||
      get_in(response, [:runner_metadata, :completed_signal_id]) ||
      get_in(response, ["runner_metadata", "completed_signal_id"])
  end

  defp confirmation_id(response) do
    response_field(response, :confirmation_id) ||
      get_in(response, [:approval_handoff, :confirmation_id]) ||
      get_in(response, ["approval_handoff", "confirmation_id"]) ||
      get_in(response, [:confirmation, :id]) ||
      get_in(response, ["confirmation", "id"])
  end

  defp response_error(response) do
    case response_field(response, :error) do
      nil -> %{}
      error -> Redactor.redact(%{reason: inspect(error)})
    end
  end

  defp action_log(response) do
    %{
      status: response_field(response, :status),
      message: response_field(response, :message),
      actions: response_field(response, :actions),
      runner_metadata: response_field(response, :runner_metadata)
    }
    |> drop_nil_values()
    |> Redactor.redact()
    |> json_safe()
  end

  defp resource_access_payload(nil), do: %{}

  defp resource_access_payload(entries) when is_list(entries),
    do: %{entries: Redactor.redact(entries)} |> json_safe()

  defp resource_access_payload(%{} = entries), do: entries |> Redactor.redact() |> json_safe()
  defp resource_access_payload(other), do: %{value: Redactor.redact(other)} |> json_safe()

  defp redacted_map(nil), do: %{}
  defp redacted_map(%{} = map), do: map |> Redactor.redact() |> json_safe()
  defp redacted_map(other), do: %{value: Redactor.redact(other)} |> json_safe()

  defp update_job_after_run(job, run) do
    attrs =
      %{last_run_at: run.finished_at}
      |> maybe_block_job(run)

    job
    |> Job.changeset(attrs)
    |> Repo.update()
  end

  defp maybe_block_job(attrs, %{status: "needs_confirmation", confirmation_id: confirmation_id})
       when is_binary(confirmation_id) do
    Map.merge(attrs, %{
      status: "blocked",
      blocked_confirmation_id: confirmation_id,
      next_due_at: nil
    })
  end

  defp maybe_block_job(attrs, _run), do: attrs

  defp response_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp atomize_existing_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {existing_atom_key(key), atomize_existing_keys(value)} end)
  end

  defp atomize_existing_keys(list) when is_list(list),
    do: Enum.map(list, &atomize_existing_keys/1)

  defp atomize_existing_keys(value), do: value

  defp existing_atom_key(key) when is_atom(key), do: key

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp existing_atom_key(key), do: key

  defp to_map(opts) when is_map(opts), do: opts
  defp to_map(opts) when is_list(opts), do: Map.new(opts)
  defp to_map(_opts), do: %{}

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp json_safe(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp json_safe(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)

  defp json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {json_safe_key(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp json_safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_safe(value), do: inspect(value)

  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key), do: to_string(key)

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
