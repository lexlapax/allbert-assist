defmodule AllbertAssist.Operator.Inspection do
  @moduledoc """
  Redacted operator inspection reports shared by console and CLI surfaces.

  This module is a read-only facade. Runtime surfaces must reach it through
  registered actions so inspection requests still cross the action boundary.
  """

  import Ecto.Query

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings

  @default_event_limit 10
  @max_event_limit 50

  @spec status(map()) :: map()
  def status(context \\ %{}) when is_map(context) do
    %{
      generated_at: DateTime.utc_now(),
      node: node() |> Atom.to_string(),
      beam_os_pid: :os.getpid() |> to_string(),
      uptime_ms: uptime_ms(),
      channel: context_value(context, :channel),
      operator_id: context_value(context, :operator_id),
      user_id: context_value(context, :user_id),
      external_user_id: context_value(context, :external_user_id),
      channels_supervisor: supervisor_report(AllbertAssist.Channels.Supervisor)
    }
    |> Redactor.redact(:cli)
  end

  @spec channels(map()) :: map()
  def channels(_context \\ %{}) do
    channels =
      Channels.list_channels()
      |> Redactor.redact(:cli)

    %{
      count: length(channels),
      channels: channels,
      channels_supervisor: supervisor_report(AllbertAssist.Channels.Supervisor)
    }
  end

  @spec events(map()) :: map()
  def events(params \\ %{}) when is_map(params) do
    limit = event_limit(params)

    events =
      Repo.all(
        from event in Event,
          order_by: [desc: event.inserted_at],
          limit: ^limit
      )
      |> Enum.map(&event_summary/1)

    %{count: length(events), limit: limit, events: events}
  end

  @spec confirmations(map()) :: map()
  def confirmations(params \\ %{}) when is_map(params) do
    status = Map.get(params, :status) || Map.get(params, "status") || "all"

    confirmations =
      Confirmations.list(status: status)
      |> Enum.map(&Confirmations.redact_for_output/1)
      |> Redactor.redact(:cli)

    %{count: length(confirmations), status: status, confirmations: confirmations}
  end

  @spec setting(String.t(), map()) :: {:ok, map()} | {:error, :missing_key | :not_found}
  def setting(key, context \\ %{})

  def setting(key, context) when is_binary(key) do
    key = String.trim(key)

    if key == "" do
      {:error, :missing_key}
    else
      case Settings.resolve(key, context) do
        {:ok, resolved} ->
          {:ok, redacted_setting(resolved)}

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, _reason} ->
          {:error, :not_found}
      end
    end
  end

  def setting(_key, _context), do: {:error, :missing_key}

  @spec render_status(map()) :: String.t()
  def render_status(report) when is_map(report) do
    supervisor = Map.get(report, :channels_supervisor, %{})

    [
      "Operator status:",
      "- node: #{report.node}",
      "- beam_os_pid: #{report.beam_os_pid}",
      "- uptime_ms: #{report.uptime_ms}",
      "- channel: #{blank(report.channel)}",
      "- operator_id: #{blank(report.operator_id)}",
      "- user_id: #{blank(report.user_id)}",
      "- external_user_id: #{blank(report.external_user_id)}",
      "- Channels.Supervisor: #{supervisor_line(supervisor)}"
    ]
    |> Enum.join("\n")
  end

  @spec render_channels(map()) :: String.t()
  def render_channels(%{channels: channels} = report) when is_list(channels) do
    rows =
      channels
      |> Enum.map(fn channel ->
        "- #{channel.channel}: provider=#{channel.provider} enabled=#{channel.enabled} " <>
          "identities=#{channel.identity_count} release=#{channel.release_status}"
      end)

    [
      "Channels (#{report.count}):",
      rows
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec render_events(map()) :: String.t()
  def render_events(%{events: []} = report) do
    "Recent channel events (0/#{report.limit}): none"
  end

  def render_events(%{events: events} = report) when is_list(events) do
    rows =
      Enum.map(events, fn event ->
        "- #{event.id}: channel=#{event.channel} direction=#{event.direction} " <>
          "status=#{event.status} external_event_id=#{event.external_event_id} " <>
          "user_id=#{blank(event.user_id)} summary=#{blank(event.payload_summary)}"
      end)

    [
      "Recent channel events (#{report.count}/#{report.limit}):",
      rows
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec render_confirmations(map()) :: String.t()
  def render_confirmations(%{confirmations: []} = report) do
    "Confirmations (0, status=#{report.status}): none"
  end

  def render_confirmations(%{confirmations: confirmations} = report)
      when is_list(confirmations) do
    rows =
      Enum.map(confirmations, fn confirmation ->
        target = get_in(confirmation, ["target_action", "name"]) || "unknown"
        "- #{confirmation["id"]}: status=#{confirmation["status"]} target=#{target}"
      end)

    [
      "Confirmations (#{report.count}, status=#{report.status}):",
      rows
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec render_setting(map()) :: String.t()
  def render_setting(setting) when is_map(setting) do
    [
      "Setting #{setting.key}:",
      "- source: #{setting.source}",
      "- writable: #{setting.writable?}",
      "- sensitive: #{setting.sensitive?}",
      "- value: #{inspect(setting.value, limit: 20, charlists: :as_lists)}"
    ]
    |> Enum.join("\n")
  end

  @spec render_setting_error(String.t(), atom()) :: String.t()
  def render_setting_error(_key, :missing_key), do: "Usage: /settings get <key>"

  def render_setting_error(_key, :not_found), do: "Setting not found."

  defp event_summary(%Event{} = event) do
    %{
      id: event.id,
      channel: event.channel,
      provider: event.provider,
      direction: event.direction,
      status: event.status,
      external_event_id: Redactor.redact(event.external_event_id, :cli),
      external_user_id: Redactor.redact(event.external_user_id, :cli),
      external_chat_id: Redactor.redact(event.external_chat_id, :cli),
      external_message_id: Redactor.redact(event.external_message_id, :cli),
      user_id: event.user_id,
      session_id: event.session_id,
      thread_id: event.thread_id,
      input_signal_id: event.input_signal_id,
      trace_id: event.trace_id,
      reason: Redactor.redact(event.reason, :cli),
      payload_summary: Redactor.redact(event.payload_summary, :cli),
      error: Redactor.redact(event.error, :cli),
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end

  defp redacted_setting(%{sensitive?: true} = setting) do
    setting
    |> Map.take([:key, :source, :writable?, :sensitive?, :namespace])
    |> Map.put(:value, "[REDACTED]")
    |> Map.put(:layers, redact_layers(setting.layers || [], true))
  end

  defp redacted_setting(setting) do
    setting
    |> Map.take([:key, :source, :writable?, :sensitive?, :namespace])
    |> Map.put(:value, Redactor.redact(setting.value, :cli))
    |> Map.put(:layers, redact_layers(setting.layers || [], false))
  end

  defp redact_layers(layers, sensitive?) do
    Enum.map(layers, fn layer ->
      value = if sensitive?, do: "[REDACTED]", else: Redactor.redact(Map.get(layer, :value), :cli)
      Map.put(layer, :value, value)
    end)
  end

  defp supervisor_report(name) do
    case Process.whereis(name) do
      nil ->
        %{name: inspect(name), status: :not_started, child_count: 0, children: []}

      pid ->
        children =
          pid
          |> Supervisor.which_children()
          |> Enum.map(&child_report/1)

        %{
          name: inspect(name),
          status: :running,
          pid: inspect(pid),
          child_count: length(children),
          children: children
        }
    end
  rescue
    exception ->
      %{
        name: inspect(name),
        status: :unavailable,
        reason: Exception.message(exception),
        child_count: 0,
        children: []
      }
  catch
    kind, reason ->
      %{
        name: inspect(name),
        status: :unavailable,
        reason: inspect({kind, reason}),
        child_count: 0,
        children: []
      }
  end

  defp child_report({id, pid, type, modules}) do
    %{
      id: inspect(id),
      pid: inspect(pid),
      alive?: is_pid(pid) and Process.alive?(pid),
      type: type,
      modules: inspect(modules)
    }
  end

  defp uptime_ms do
    {uptime, _since_last_call} = :erlang.statistics(:wall_clock)
    uptime
  end

  defp event_limit(params) do
    params
    |> Map.get(:limit, Map.get(params, "limit", @default_event_limit))
    |> normalize_limit()
  end

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_event_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> normalize_limit(value)
      _other -> @default_event_limit
    end
  end

  defp normalize_limit(_limit), do: @default_event_limit

  defp context_value(context, key) do
    string_key = to_string(key)

    Map.get(context, key) ||
      Map.get(context, string_key) ||
      get_in(context, [:request, key]) ||
      get_in(context, [:request, string_key]) ||
      get_in(context, ["request", key]) ||
      get_in(context, ["request", string_key])
  end

  defp supervisor_line(%{status: :running} = supervisor),
    do: "running child_count=#{supervisor.child_count}"

  defp supervisor_line(%{status: status} = supervisor),
    do: "#{status} child_count=#{supervisor.child_count}"

  defp blank(nil), do: "n/a"
  defp blank(""), do: "n/a"
  defp blank(value), do: to_string(value)
end
