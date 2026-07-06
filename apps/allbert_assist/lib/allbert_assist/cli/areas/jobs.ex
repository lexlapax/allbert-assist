defmodule AllbertAssist.CLI.Areas.Jobs do
  @moduledoc """
  Release-safe `jobs` admin dispatch (v0.62 M8.7).

  The single source of truth for `mix allbert.jobs` and `allbert admin jobs`:
  `dispatch/2` parses the sub-argv, reads through `AllbertAssist.Jobs`, and routes
  every mutation (create/pause/resume/run) through
  `AllbertAssist.Actions.Runner.run/3` so each write clears PermissionGate + audit
  on the one spine (v0.62 M8.15). It returns `{rendered_output, exit_code}` — no
  `Mix.*` calls, so it runs inside the packaged release. `Mix.Tasks.Allbert.Jobs`
  is a thin wrapper that prints the output through `Mix.shell/0` (raising a
  `Mix.Error` on failure).

  Job commands do not consume the surface context, so `dispatch/2` accepts and
  ignores the second argument for signature parity with the other areas.
  """

  alias AllbertAssist.Actions.ErrorExtraction
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Jobs.Templates
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Surfaces.ContextBuilder

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

  @usage """
  Usage:
    allbert admin jobs list [--user USER] [--status active|paused|blocked]
    allbert admin jobs show JOB_ID
    allbert admin jobs runs JOB_ID [--limit N]
    allbert admin jobs pause JOB_ID
    allbert admin jobs resume JOB_ID
    allbert admin jobs run JOB_ID
    allbert admin jobs templates
    allbert admin jobs create runtime-prompt NAME --prompt TEXT [--manual|--daily HH:MM|--weekly WEEKDAY@HH:MM|--cron EXPR]
    allbert admin jobs create template TEMPLATE_NAME [--name NAME] [--manual|--daily HH:MM|--weekly WEEKDAY@HH:MM|--cron EXPR]
  """

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, _context \\ nil) do
    result =
      try do
        route(argv)
      catch
        {:jobs_error, message} -> {:error, {:message, message}}
      end

    render(result)
  end

  defp route(["list" | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)
    status = job_status_filter(opts)
    user_id = identity!(opts).user_id

    {:ok, {:list, Jobs.list_jobs(user_id, status: status)}}
  end

  defp route(["show", id]) do
    with {:ok, job} <- Jobs.get_job(id) do
      {:ok, {:show, job}}
    end
  end

  defp route(["runs", id | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    with {:ok, job} <- Jobs.get_job(id) do
      {:ok, {:runs, job, Jobs.list_runs(job, limit: opts[:limit] || 20)}}
    end
  end

  defp route(["pause", id]) do
    with {:ok, job} <- Jobs.get_job(id),
         {:ok, _response} <- job_action("pause_job", %{id: id}, job_context(job)),
         {:ok, updated} <- Jobs.get_job(id) do
      {:ok, {:updated, updated}}
    end
  end

  defp route(["resume", id]) do
    with {:ok, job} <- Jobs.get_job(id),
         {:ok, _response} <- job_action("resume_job", %{id: id}, job_context(job)),
         {:ok, updated} <- Jobs.get_job(id) do
      {:ok, {:updated, updated}}
    end
  end

  defp route(["run", id]) do
    with {:ok, job} <- Jobs.get_job(id),
         {:ok, _response} <- job_action("run_job", %{id: id}, job_context(job)),
         {:ok, run} <- latest_run(job) do
      {:ok, {:run, %{run: run, response: run_response(run)}}}
    end
  end

  defp route(["templates"]) do
    {:ok, {:templates, Templates.templates()}}
  end

  defp route(["create", "runtime-prompt", name | rest]) do
    {opts, [], invalid} = parse!(rest)
    reject_invalid!(invalid)

    prompt =
      opts[:prompt]
      |> blank_to_nil()
      |> case do
        nil -> fail!("--prompt is required for runtime-prompt jobs")
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

  defp route(["create", "template", template | rest]) do
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

  defp route(_args), do: {:usage, @usage}

  defp render({:ok, {:list, []}}), do: Render.ok("No jobs.")

  defp render({:ok, {:list, jobs}}) do
    Render.ok(Enum.map(jobs, &job_list_line/1))
  end

  defp render({:ok, {:show, %Job{} = job}}) do
    Render.ok([
      "Job: #{job.id}",
      "Name: #{job.name}",
      "Status: #{job.status}",
      "Schedule: #{schedule_text(job.schedule)} timezone=#{job.timezone}",
      "Target: #{job.target_type} #{inspect(Redactor.redact(job.target), pretty: true)}",
      "User: #{job.user_id}",
      "Operator: #{job.operator_id}",
      "Thread: #{thread_text(job)}",
      "Session: #{job.session_id || "none"}",
      "App: #{job.app_id || "general"}",
      "Next due: #{datetime_text(job.next_due_at)}",
      "Last run: #{datetime_text(job.last_run_at)}",
      "Blocked confirmation: #{job.blocked_confirmation_id || "none"}",
      "Metadata: #{inspect(Redactor.redact(job.metadata), pretty: true)}"
    ])
  end

  defp render({:ok, {:runs, _job, []}}), do: Render.ok("No runs.")

  defp render({:ok, {:runs, _job, runs}}) do
    Render.ok(Enum.flat_map(runs, &run_lines/1))
  end

  defp render({:ok, {:updated, %Job{} = job}}) do
    Render.ok("Updated #{job.id} status=#{job.status} next=#{datetime_text(job.next_due_at)}")
  end

  defp render({:ok, {:created, %Job{} = job}}) do
    Render.ok("Created #{job.id} name=#{job.name} status=#{job.status}")
  end

  defp render({:ok, {:run, %{run: %Run{} = run, response: response}}}) do
    Render.ok(run_lines(run) ++ run_message_lines(response))
  end

  defp render({:ok, {:templates, templates}}) do
    Render.ok(
      Enum.map(templates, fn template ->
        "#{template.name} target=#{template.target_type} description=#{template.description}"
      end)
    )
  end

  # v0.62 M8.15: a blocked-by-confirmation now arrives through the gated action
  # as {:error, {:message, ...}} (job_action/3), so no dedicated clause is needed.
  defp render({:error, {:message, message}}), do: Render.error(message)
  defp render({:usage, usage}), do: Render.usage(usage)
  defp render({:error, reason}), do: Render.error("Jobs command failed: #{inspect(reason)}")

  defp job_list_line(job) do
    "#{job.id} #{job.name} status=#{job.status} schedule=#{schedule_text(job.schedule)} user=#{job.user_id} thread=#{thread_text(job)} next=#{datetime_text(job.next_due_at)} last=#{datetime_text(job.last_run_at)}"
  end

  defp run_message_lines(response) do
    if response && Map.get(response, :message) do
      ["", Map.get(response, :message)]
    else
      []
    end
  end

  defp run_lines(%Run{} = run) do
    [
      "#{run.id} status=#{run.status} trigger=#{run.trigger} started=#{datetime_text(run.started_at)} duration_ms=#{run.duration_ms || "none"} signal=#{run.response_signal_id || "none"} trace=#{run.trace_id || "none"} confirmation=#{run.confirmation_id || "none"}"
      | handoff_lines(run)
    ]
  end

  defp handoff_lines(%Run{confirmation_id: nil}), do: []

  defp handoff_lines(%Run{approval_handoff: handoff, confirmation_id: confirmation_id}) do
    lines = ApprovalHandoff.lines(handoff)

    handoff_section =
      if lines != [] do
        ["Approval Handoff:" | Enum.map(lines, &"  #{&1}")]
      else
        []
      end

    handoff_section ++
      [
        "Details: mix allbert.confirmations show #{confirmation_id}",
        "Approve: mix allbert.confirmations approve #{confirmation_id}",
        "Deny: mix allbert.confirmations deny #{confirmation_id}"
      ]
  end

  defp create_job(attrs) do
    ctx = cli_context(attrs[:user_id], attrs[:operator_id])

    with {:ok, response} <-
           job_action("create_job", %{attrs: attrs, user_id: attrs[:user_id]}, ctx) do
      {:ok, {:created, response.job}}
    end
  end

  # -- action + read helpers -------------------------------------------------

  defp job_action(action_name, params, ctx) do
    case Runner.run(action_name, params, ctx) do
      {:ok, %{status: :completed} = response} -> {:ok, response}
      {:ok, response} -> {:error, {:message, action_message(response)}}
    end
  end

  defp action_message(response) do
    case Map.get(response, :message) do
      message when is_binary(message) and message != "" ->
        message

      _other ->
        "Jobs command failed: #{inspect(ErrorExtraction.from_response(response))}"
    end
  end

  defp latest_run(job) do
    case Jobs.list_runs(job, limit: 1) do
      [run | _rest] -> {:ok, run}
      [] -> {:error, :run_not_found}
    end
  end

  defp run_response(%Run{action_log: action_log}) when is_map(action_log) do
    case Map.get(action_log, "message") || Map.get(action_log, :message) do
      message when is_binary(message) and message != "" -> %{message: message}
      _other -> nil
    end
  end

  defp run_response(_run), do: nil

  defp job_context(%Job{} = job), do: cli_context(job.user_id, job.operator_id)

  defp cli_context(user_id, operator_id) do
    ContextBuilder.cli_context(
      actor: user_id,
      user_id: user_id,
      operator_id: operator_id,
      surface: "allbert admin jobs"
    )
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
        fail!("--user and --operator must match when both are provided")

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
        fail!("--thread, --recent-thread, and --new-thread-per-run are mutually exclusive")

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
      _multiple -> fail!("Choose only one schedule option")
    end
  end

  defp weekly_schedule!(value) do
    case String.split(value, "@", parts: 2) do
      [weekday, at] -> %{kind: "weekly", weekday: weekday, at: at}
      _other -> fail!("--weekly must use WEEKDAY@HH:MM")
    end
  end

  defp job_status_filter(opts) do
    case blank_to_nil(opts[:status]) do
      nil ->
        nil

      status when status in @allowed_statuses ->
        status

      status ->
        fail!("--status must be one of: #{Enum.join(@allowed_statuses, ", ")}; got #{status}")
    end
  end

  defp parse!(args) do
    OptionParser.parse(args, switches: @switches, aliases: @aliases)
  end

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: fail!("Invalid option(s): #{inspect(invalid)}")

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

  @spec fail!(String.t()) :: no_return()
  defp fail!(message), do: throw({:jobs_error, message})
end
