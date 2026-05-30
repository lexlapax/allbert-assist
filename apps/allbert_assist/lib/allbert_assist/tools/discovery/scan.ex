defmodule AllbertAssist.Tools.Discovery.Scan do
  @moduledoc """
  Managed background scan job for inert MCP discovery suggestions.
  """

  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Runner
  alias AllbertAssist.Settings

  @job_name "mcp-discovery-scan"
  @default_user "local"
  @default_query ""
  @default_daily_at "09:00"
  @default_weekly_day "monday"

  @doc "Create or refresh the paused discovery scan job."
  def ensure_job(opts \\ []) do
    opts = opts_map(opts)
    user_id = identity(opts, :user_id)

    case existing_job(user_id) do
      %Job{} = job -> refresh_job(job, opts)
      nil -> Jobs.create_job(job_attrs(opts, "paused"))
    end
  end

  @doc "Enable MCP discovery and ensure the scan job exists, still paused."
  def enable(opts \\ []) do
    with {:ok, _setting} <- Settings.put("mcp.discovery.enabled", true, %{audit?: false}) do
      ensure_job(opts)
    end
  end

  @doc "Pause the managed discovery scan job."
  def pause(opts \\ []) do
    with {:ok, job} <- ensure_job(opts) do
      Jobs.pause_job(job)
    end
  end

  @doc "Resume the managed discovery scan job only when discovery is enabled."
  def resume(opts \\ []) do
    with :ok <- require_enabled(),
         {:ok, job} <- ensure_job(opts) do
      Jobs.resume_job(job)
    end
  end

  @doc "Run the managed discovery scan once through the scheduled-job runner."
  def run_once(query \\ nil, opts \\ []) do
    opts = opts_map(opts)

    with :ok <- require_enabled(),
         {:ok, job} <- ensure_job(Map.put(opts, :query, query || query(opts))),
         {:ok, job} <- refresh_job(job, Map.put(opts, :query, query || query(opts))) do
      Runner.run_now(job, action_context: Map.get(opts, :action_context, %{}))
    end
  end

  @doc "Return the managed discovery scan job if it exists."
  def get_job(opts \\ []) do
    opts = opts_map(opts)

    case existing_job(identity(opts, :user_id)) do
      %Job{} = job -> {:ok, job}
      nil -> {:error, :not_found}
    end
  end

  defp existing_job(user_id) do
    user_id
    |> Jobs.list_jobs(limit: 100)
    |> Enum.find(&(&1.name == @job_name))
  end

  defp refresh_job(%Job{} = job, opts) do
    Jobs.update_job(job, %{
      target: target(opts),
      schedule: schedule(),
      status: job.status,
      metadata: metadata()
    })
  end

  defp job_attrs(opts, status) do
    user_id = identity(opts, :user_id)

    %{
      name: @job_name,
      description: "Opt-in MCP registry discovery scan.",
      target_type: "registered_action",
      target: target(opts),
      schedule: schedule(),
      status: status,
      user_id: user_id,
      operator_id: identity(opts, :operator_id, user_id),
      metadata: metadata()
    }
  end

  defp target(opts) do
    %{
      action_name: "find_mcp_tools",
      params: %{
        query: query(opts),
        limit: max_results()
      }
    }
  end

  defp metadata do
    %{
      managed_by: "allbert.mcp.scan",
      discovery_surface: "core_discovery_suggestions_panel"
    }
  end

  defp schedule do
    case setting("mcp.discovery.scan.schedule", "paused") do
      "daily" -> %{kind: "daily", at: @default_daily_at}
      "weekly" -> %{kind: "weekly", weekday: @default_weekly_day, at: @default_daily_at}
      _other -> %{kind: "manual"}
    end
  end

  defp max_results do
    case setting("mcp.discovery.scan.max_results", 25) do
      value when is_integer(value) and value > 0 -> min(value, 100)
      _value -> 25
    end
  end

  defp require_enabled do
    if setting("mcp.discovery.enabled", false) == true do
      :ok
    else
      {:error, :discovery_disabled}
    end
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  end

  defp identity(opts, field, fallback \\ @default_user) do
    value =
      Map.get(opts, field) ||
        Map.get(opts, Atom.to_string(field)) ||
        Map.get(opts, :user) ||
        Map.get(opts, "user")

    case value do
      value when is_binary(value) and value != "" -> value
      _value -> fallback
    end
  end

  defp query(opts) do
    case Map.get(opts, :query, Map.get(opts, "query", @default_query)) do
      value when is_binary(value) -> String.trim(value)
      nil -> @default_query
      value -> value |> to_string() |> String.trim()
    end
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(_opts), do: %{}
end
