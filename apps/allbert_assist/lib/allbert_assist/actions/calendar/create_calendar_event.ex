defmodule AllbertAssist.Actions.Calendar.CreateCalendarEvent do
  @moduledoc """
  v0.54 M10 (ADR 0063) — create a calendar event via a connected Google Calendar
  **MCP** server (no new OAuth/credential custody in Allbert). The server id is
  configurable (`intent.calendar_mcp_server`, default `"calendar"`); the tool is
  `create_event`. If no calendar MCP server is connected, the action degrades
  gracefully to an `:answer` ("connect a calendar MCP server") — never a hard
  failure. Effectful → `confirmation: :required` via `Actions.Outbound.Gate`; the
  underlying MCP call is itself confirmation-gated at the client (double-gated).
  """
  use AllbertAssist.Action,
    permission: :calendar_write,
    exposure: :agent,
    execution_mode: :mcp_tool_call,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "create_calendar_event",
    description: "Create a calendar event via a connected calendar MCP server.",
    category: "calendar",
    tags: ["calendar", "outbound", "mcp"],
    schema: [
      title: [type: :string, required: true],
      start: [type: :string, required: true],
      end: [type: :string, required: false],
      duration: [type: :string, required: false],
      attendees: [type: :string, required: false],
      location: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Outbound.Gate
  alias AllbertAssist.Mcp.Client, as: McpClient
  alias AllbertAssist.Mcp.ServerConfig
  alias AllbertAssist.Settings

  @tool "create_event"

  def intent_descriptors do
    [
      %{
        action_name: "create_calendar_event",
        label: "Create a calendar event",
        examples: [
          "schedule a meeting tomorrow at 3pm",
          "schedule a meeting tomorrow 3pm titled sync",
          "create a calendar event called launch review tomorrow at 10am"
        ],
        synonyms: ["schedule meeting", "create calendar event", "add calendar event"],
        required_slots: [:title, :start],
        optional_slots: [:duration, :attendees, :location],
        slot_extractors: %{
          title: :calendar_title_phrase,
          start: :calendar_start_phrase
        },
        handoff_required?: true
      }
    ]
  end

  @impl true
  def run(params, context) do
    with {:ok, title} <- required(params, :title),
         {:ok, start} <- required(params, :start),
         {:ok, config} <- calendar_server() do
      Gate.run(
        %{
          action_name: "create_calendar_event",
          permission: :calendar_write,
          execution_mode: :mcp_tool_call,
          summary: %{title: title, start: start},
          resume_params: stringify(arguments(title, start, params))
        },
        context,
        fn -> call(config, arguments(title, start, params), context) end
      )
    else
      {:error, :no_calendar_server} ->
        {:ok,
         %{
           message:
             "I can't create calendar events yet — connect a calendar MCP server " <>
               "(set `intent.calendar_mcp_server`).",
           status: :answer,
           actions: []
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "create_calendar_event: #{inspect(reason)}",
           status: :failed,
           error: reason,
           actions: []
         }}
    end
  end

  defp calendar_server do
    case ServerConfig.resolve(server_id()) do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> {:error, :no_calendar_server}
    end
  end

  defp server_id do
    case Settings.get("intent.calendar_mcp_server") do
      {:ok, value} when is_binary(value) and value != "" -> value
      _other -> "calendar"
    end
  end

  defp arguments(title, start, params) do
    %{
      "title" => title,
      "start" => start,
      "end" => field(params, :end),
      "duration" => field(params, :duration),
      "attendees" => field(params, :attendees),
      "location" => field(params, :location)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp call(config, arguments, context) do
    case McpClient.call_tool(config, @tool, arguments, context) do
      {:ok, result} -> {:ok, %{tool: @tool, result: result}}
      {:error, reason} -> {:error, {:mcp_call_failed, reason}}
    end
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp required(params, key) do
    case field(params, key) do
      value when is_binary(value) and value != "" -> {:ok, String.trim(value)}
      _other -> {:error, {:missing, key}}
    end
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_map, _key), do: nil
end
