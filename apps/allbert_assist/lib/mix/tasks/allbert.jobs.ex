defmodule Mix.Tasks.Allbert.Jobs do
  @moduledoc """
  Manage local scheduled jobs.

  ## Usage

      mix allbert.jobs list [--user USER] [--status active|paused|blocked]
      mix allbert.jobs show JOB_ID
      mix allbert.jobs runs JOB_ID [--limit N]
      mix allbert.jobs pause JOB_ID
      mix allbert.jobs resume JOB_ID
      mix allbert.jobs run JOB_ID
      mix allbert.jobs templates
      mix allbert.jobs create runtime-prompt NAME --prompt TEXT [--manual|--daily HH:MM|--weekly WEEKDAY@HH:MM|--cron EXPR]
      mix allbert.jobs create template TEMPLATE_NAME [--name NAME] [--manual|--daily HH:MM|--weekly WEEKDAY@HH:MM|--cron EXPR]
  """

  use Mix.Task

  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Jobs.Runner
  alias AllbertAssist.Jobs.Templates
  alias AllbertAssist.Security.Redactor

  @shortdoc "Manage local scheduled jobs"

  @switches [
    active: :boolean,
    cron: :string,
    daily: :string,
    description: :string,
    limit: :integer,
    manual: :boolean,
    name: :string,
    new_thread_per_run: :boolean,
    operator: :string,
    prompt: :string,
    recent_thread: :boolean,
    status: :string,
    thread: :string,
    timezone: :string,
    user: :string,
    weekly: :string
  ]

  @aliases [
    o: :operator,
    p: :prompt,
    t: :thread,
    u: :user
  ]

  @allowed_statuses ~w[active paused blocked]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    args
    |> dispatch()
    |> print_result()
  end

  defp dispatch(["list" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    status = job_status_filter(opts)
    user_id = identity!(opts).user_id

    {:ok, {:list, Jobs.list_jobs(user_id, status: status)}}
  end

  defp dispatch(["show", id]) do
    with {:ok, job} <- Jobs.get_job(id) do
      {:ok, {:show, job}}
    end
  end

  defp dispatch(["runs", id | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    with {:ok, job} <- Jobs.get_job(id) do
      {:ok, {:runs, job, Jobs.list_runs(job, limit: opts[:limit] || 20)}}
    end
  end

  defp dispatch(["pause", id]) do
    with {:ok, job} <- Jobs.get_job(id),
         {:ok, paused} <- Jobs.pause_job(job) do
      {:ok, {:updated, paused}}
    end
  end

  defp dispatch(["resume", id]) do
    with {:ok, job} <- Jobs.get_job(id),
         {:ok, resumed} <- Jobs.resume_job(job) do
      {:ok, {:updated, resumed}}
    end
  end

  defp dispatch(["run", id]) do
    with {:ok, result} <- Runner.run_now(id) do
      {:ok, {:run, result}}
    end
  end

  defp dispatch(["templates"]) do
    {:ok, {:templates, Templates.templates()}}
  end

  defp dispatch(["create", "runtime-prompt", name | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    prompt =
      opts[:prompt]
      |> blank_to_nil()
      |> case do
        nil -> Mix.raise("--prompt is required for runtime-prompt jobs")
        prompt -> prompt
      end

    attrs =
      %{
        name: name,
        description: opts[:description],
        target_type: "runtime_prompt",
        target: %{text: prompt}
      }
      |> merge_common_attrs(opts)

    create_job(attrs)
  end

  defp dispatch(["create", "template", template | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    with {:ok, attrs} <-
           Templates.expand(template, %{
             name: blank_to_nil(opts[:name]),
             description: blank_to_nil(opts[:description]),
             prompt: blank_to_nil(opts[:prompt])
           }) do
      attrs
      |> merge_common_attrs(opts)
      |> create_job()
    end
  end

  defp dispatch(_args) do
    Mix.raise("""
    Usage:
      mix allbert.jobs list [--user USER] [--status active|paused|blocked]
      mix allbert.jobs show JOB_ID
      mix allbert.jobs runs JOB_ID [--limit N]
      mix allbert.jobs pause JOB_ID
      mix allbert.jobs resume JOB_ID
      mix allbert.jobs run JOB_ID
      mix allbert.jobs templates
      mix allbert.jobs create runtime-prompt NAME --prompt TEXT [--manual|--daily HH:MM|--weekly WEEKDAY@HH:MM|--cron EXPR]
      mix allbert.jobs create template TEMPLATE_NAME [--name NAME] [--manual|--daily HH:MM|--weekly WEEKDAY@HH:MM|--cron EXPR]
    """)
  end

  defp print_result({:ok, {:list, []}}), do: Mix.shell().info("No jobs.")

  defp print_result({:ok, {:list, jobs}}) do
    Enum.each(jobs, fn job ->
      Mix.shell().info(
        "#{job.id} #{job.name} status=#{job.status} schedule=#{schedule_text(job.schedule)} user=#{job.user_id} thread=#{thread_text(job)} next=#{datetime_text(job.next_due_at)} last=#{datetime_text(job.last_run_at)}"
      )
    end)
  end

  defp print_result({:ok, {:show, %Job{} = job}}) do
    Mix.shell().info("Job: #{job.id}")
    Mix.shell().info("Name: #{job.name}")
    Mix.shell().info("Status: #{job.status}")
    Mix.shell().info("Schedule: #{schedule_text(job.schedule)} timezone=#{job.timezone}")

    Mix.shell().info(
      "Target: #{job.target_type} #{inspect(Redactor.redact(job.target), pretty: true)}"
    )

    Mix.shell().info("User: #{job.user_id}")
    Mix.shell().info("Operator: #{job.operator_id}")
    Mix.shell().info("Thread: #{thread_text(job)}")
    Mix.shell().info("Session: #{job.session_id || "none"}")
    Mix.shell().info("App: #{job.app_id || "general"}")
    Mix.shell().info("Next due: #{datetime_text(job.next_due_at)}")
    Mix.shell().info("Last run: #{datetime_text(job.last_run_at)}")
    Mix.shell().info("Blocked confirmation: #{job.blocked_confirmation_id || "none"}")
    Mix.shell().info("Metadata: #{inspect(Redactor.redact(job.metadata), pretty: true)}")
  end

  defp print_result({:ok, {:runs, _job, []}}), do: Mix.shell().info("No runs.")

  defp print_result({:ok, {:runs, _job, runs}}) do
    Enum.each(runs, &print_run/1)
  end

  defp print_result({:ok, {:updated, %Job{} = job}}) do
    Mix.shell().info(
      "Updated #{job.id} status=#{job.status} next=#{datetime_text(job.next_due_at)}"
    )
  end

  defp print_result({:ok, {:created, %Job{} = job}}) do
    Mix.shell().info("Created #{job.id} name=#{job.name} status=#{job.status}")
  end

  defp print_result({:ok, {:run, %{run: %Run{} = run, response: response}}}) do
    print_run(run)

    if response && Map.get(response, :message) do
      Mix.shell().info("")
      Mix.shell().info(Map.get(response, :message))
    end
  end

  defp print_result({:ok, {:templates, templates}}) do
    Enum.each(templates, fn template ->
      Mix.shell().info(
        "#{template.name} target=#{template.target_type} description=#{template.description}"
      )
    end)
  end

  defp print_result({:error, {:blocked_by_confirmation, confirmation_id}}) do
    Mix.raise(
      "Job is blocked by pending confirmation #{confirmation_id}. Inspect it with: mix allbert.confirmations show #{confirmation_id}"
    )
  end

  defp print_result({:error, reason}) do
    Mix.raise("Jobs command failed: #{inspect(reason)}")
  end

  defp print_run(%Run{} = run) do
    Mix.shell().info(
      "#{run.id} status=#{run.status} trigger=#{run.trigger} started=#{datetime_text(run.started_at)} duration_ms=#{run.duration_ms || "none"} signal=#{run.response_signal_id || "none"} trace=#{run.trace_id || "none"} confirmation=#{run.confirmation_id || "none"}"
    )

    print_handoff(run)
  end

  defp print_handoff(%Run{confirmation_id: nil}), do: :ok

  defp print_handoff(%Run{approval_handoff: handoff, confirmation_id: confirmation_id}) do
    lines = ApprovalHandoff.lines(handoff)

    if lines != [] do
      Mix.shell().info("Approval Handoff:")
      Enum.each(lines, &Mix.shell().info("  #{&1}"))
    end

    Mix.shell().info("Details: mix allbert.confirmations show #{confirmation_id}")
    Mix.shell().info("Approve: mix allbert.confirmations approve #{confirmation_id}")
    Mix.shell().info("Deny: mix allbert.confirmations deny #{confirmation_id}")
  end

  defp create_job(attrs) do
    with {:ok, job} <- Jobs.create_job(attrs) do
      {:ok, {:created, job}}
    end
  end

  defp merge_common_attrs(attrs, opts) do
    identity = identity!(opts)

    attrs
    |> Map.put(:user_id, identity.user_id)
    |> Map.put(:operator_id, identity.operator_id)
    |> maybe_put(:schedule, schedule!(opts))
    |> maybe_put(:timezone, blank_to_nil(opts[:timezone]))
    |> maybe_put(:status, if(opts[:active], do: "active"))
    |> maybe_put(:thread_id, blank_to_nil(opts[:thread]))
    |> maybe_put(:thread_mode, thread_mode!(opts))
  end

  defp identity!(opts) do
    user = blank_to_nil(opts[:user])
    operator = blank_to_nil(opts[:operator])

    cond do
      user && operator && user != operator ->
        Mix.raise("--user and --operator must match when both are provided")

      user ->
        %{user_id: user, operator_id: user}

      operator ->
        %{user_id: operator, operator_id: operator}

      true ->
        %{user_id: "local", operator_id: "local"}
    end
  end

  defp thread_mode!(opts) do
    thread = blank_to_nil(opts[:thread])
    recent? = opts[:recent_thread]
    new? = opts[:new_thread_per_run]

    cond do
      Enum.count([thread, recent?, new?], &present?/1) > 1 ->
        Mix.raise("--thread, --recent-thread, and --new-thread-per-run are mutually exclusive")

      recent? ->
        "recent_general"

      new? ->
        "new_thread_per_run"

      true ->
        nil
    end
  end

  defp schedule!(opts) do
    selected =
      [
        manual: opts[:manual],
        daily: blank_to_nil(opts[:daily]),
        weekly: blank_to_nil(opts[:weekly]),
        cron: blank_to_nil(opts[:cron])
      ]
      |> Enum.filter(fn
        {_kind, nil} -> false
        {_kind, false} -> false
        _other -> true
      end)

    case selected do
      [] -> %{kind: "manual"}
      [manual: true] -> %{kind: "manual"}
      [daily: at] -> %{kind: "daily", at: at}
      [weekly: weekly] -> weekly_schedule!(weekly)
      [cron: expression] -> %{kind: "cron", expression: expression}
      _multiple -> Mix.raise("Choose only one schedule option")
    end
  end

  defp weekly_schedule!(value) do
    case String.split(value, "@", parts: 2) do
      [weekday, at] -> %{kind: "weekly", weekday: weekday, at: at}
      _other -> Mix.raise("--weekly must use WEEKDAY@HH:MM")
    end
  end

  defp job_status_filter(opts) do
    case blank_to_nil(opts[:status]) do
      nil ->
        nil

      status when status in @allowed_statuses ->
        status

      status ->
        Mix.raise("--status must be one of: #{Enum.join(@allowed_statuses, ", ")}; got #{status}")
    end
  end

  defp parse!(args) do
    OptionParser.parse(args, switches: @switches, aliases: @aliases)
  end

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: Mix.raise("Invalid option(s): #{inspect(invalid)}")

  defp schedule_text(%{"kind" => "manual"}), do: "manual"
  defp schedule_text(%{"kind" => "daily", "at" => at}), do: "daily@#{at}"

  defp schedule_text(%{"kind" => "weekly", "weekday" => weekday, "at" => at}) do
    "weekly:#{weekday}@#{at}"
  end

  defp schedule_text(%{"kind" => "cron", "expression" => expression}), do: "cron:#{expression}"
  defp schedule_text(schedule), do: inspect(schedule)

  defp thread_text(%Job{thread_mode: "origin_thread", thread_id: thread_id}),
    do: "origin:#{thread_id}"

  defp thread_text(%Job{thread_mode: "new_thread_per_run"}), do: "new_per_run"
  defp thread_text(_job), do: "recent"

  defp datetime_text(nil), do: "none"
  defp datetime_text(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_text(value), do: to_string(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp present?(value), do: value not in [nil, false, ""]
end
