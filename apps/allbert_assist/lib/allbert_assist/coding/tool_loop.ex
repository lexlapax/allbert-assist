defmodule AllbertAssist.Coding.ToolLoop do
  @moduledoc """
  Session-local ReqLLM tool bindings for the v0.57 Pi-mode coding loop.

  This module grants no authority. It binds the six coding actions as
  model-callable `ReqLLM.Tool` values for an already-active Pi-mode coding turn.
  Every callback invokes `AllbertAssist.Actions.Runner.run/3`; filesystem, shell,
  confirmation, and tier decisions remain owned by the registered actions and
  Security Central.
  """

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Runtime.Response

  @max_tool_result_bytes 12_000

  @tool_specs [
    %{
      name: "read",
      description: "Read a bounded file chunk inside the pinned Pi-mode cwd jail.",
      schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "offset" => %{"type" => "integer"},
          "limit" => %{"type" => "integer"},
          "max_bytes" => %{"type" => "integer"}
        },
        "required" => ["path"]
      }
    },
    %{
      name: "grep",
      description: "Search text inside the pinned Pi-mode cwd jail with bounded output.",
      schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string"},
          "path" => %{"type" => "string"},
          "regex" => %{"type" => "boolean"},
          "case_sensitive" => %{"type" => "boolean"},
          "max_results" => %{"type" => "integer"},
          "max_output_bytes" => %{"type" => "integer"}
        },
        "required" => ["pattern"]
      }
    },
    %{
      name: "glob",
      description: "Find paths inside the pinned Pi-mode cwd jail.",
      schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string"},
          "max_results" => %{"type" => "integer"},
          "max_output_bytes" => %{"type" => "integer"}
        },
        "required" => ["pattern"]
      }
    },
    %{
      name: "write",
      description: "Create one new file inside the pinned Pi-mode cwd jail.",
      schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "content" => %{"type" => "string"},
          "max_bytes" => %{"type" => "integer"},
          "source_text" => %{"type" => "string"}
        },
        "required" => ["path", "content"]
      }
    },
    %{
      name: "edit",
      description: "Apply an exact-match replacement inside one existing file.",
      schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "old_text" => %{"type" => "string"},
          "new_text" => %{"type" => "string"},
          "max_replacements" => %{"type" => "integer"},
          "max_bytes" => %{"type" => "integer"},
          "source_text" => %{"type" => "string"}
        },
        "required" => ["path", "old_text", "new_text"]
      }
    },
    %{
      name: "bash",
      description:
        "Run a cwd-jailed Level 1 command with timeout, output caps, and redaction. Prefer executable plus args; plain command strings are normalized to argv when safe, while shell syntax requires the raw-shell tier.",
      schema: %{
        "type" => "object",
        "properties" => %{
          "executable" => %{
            "type" => "string",
            "description" => "Executable name or absolute path, for example pwd or printf."
          },
          "args" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Argument vector. Do not include shell operators here."
          },
          "command" => %{
            "type" => "string",
            "description" =>
              "Plain command text. Simple text such as pwd or printf 'hi\\n' is converted to argv; shell operators such as pipes, redirection, &&, ;, $(), or backticks require the raw-shell tier."
          },
          "cwd" => %{
            "type" => "string",
            "description" => "Directory inside the Pi-mode cwd jail."
          },
          "timeout_ms" => %{"type" => "integer"},
          "max_output_bytes" => %{"type" => "integer"},
          "env" => %{"type" => "object"},
          "source_text" => %{"type" => "string"}
        }
      }
    }
  ]

  @doc "Return the six Pi-mode tool names in prompt order."
  @spec tool_names() :: [String.t()]
  def tool_names, do: Enum.map(@tool_specs, & &1.name)

  @doc "Build session-local ReqLLM tool structs bound to the given runner context."
  @spec tools(map()) :: {:ok, [ReqLLM.Tool.t()]} | {:error, term()}
  def tools(context) when is_map(context) do
    @tool_specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, tools} ->
      case ReqLLM.Tool.new(
             name: spec.name,
             description: spec.description,
             parameter_schema: spec.schema,
             callback: fn args -> run_tool(spec.name, args, context) end
           ) do
        {:ok, tool} -> {:cont, {:ok, [tool | tools]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tools} -> {:ok, Enum.reverse(tools)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Execute one model-proposed tool call against the bound ReqLLM tools."
  @spec execute(term(), [ReqLLM.Tool.t()]) :: {:ok, map()}
  def execute(tool_call, tools) when is_list(tools) do
    call = normalize_tool_call(tool_call)

    case Enum.find(tools, &(&1.name == call.name)) do
      nil ->
        {:ok, error_result(call, {:unknown_coding_tool, call.name})}

      tool ->
        case ReqLLM.Tool.execute(tool, call.arguments) do
          {:ok, result} -> {:ok, Map.merge(result, call_fields(call))}
          {:error, reason} -> {:ok, error_result(call, reason)}
        end
    end
  end

  @doc "Encode a bounded, model-visible tool result body."
  @spec result_text(map()) :: String.t()
  def result_text(result) when is_map(result) do
    result
    |> Map.drop([:actions])
    |> Jason.encode!()
    |> bound(@max_tool_result_bytes)
  rescue
    _error -> inspect(Redactor.redact(Map.drop(result, [:actions])), limit: 80)
  end

  @doc "Return response action summaries captured from Runner results."
  @spec action_summaries(map()) :: [map()]
  def action_summaries(%{actions: actions}) when is_list(actions), do: actions
  def action_summaries(_result), do: []

  defp run_tool(name, args, context) do
    args = args || %{}
    {:ok, response} = Runner.run(name, args, runner_context(name, args, context))

    {:ok, result_from_response(name, args, response, context)}
  end

  defp result_from_response(name, args, response, context) do
    normalized = Response.normalize(response)
    status = normalized.status
    ok? = status == :completed
    approval_handoff = approval_handoff(normalized, context)

    %{
      ok: ok?,
      status: Atom.to_string(status),
      tool: name,
      message:
        bound(normalized.model_payload || normalized.message || "", @max_tool_result_bytes),
      actions: summarize_actions(normalized.actions),
      requested_args: Redactor.redact(args)
    }
    |> maybe_put(:confirmation_id, field(normalized, :confirmation_id))
    |> maybe_put(:confirmation, field(normalized, :confirmation))
    |> maybe_put(:approval_handoff, approval_handoff)
    |> maybe_put(:approval_summary, approval_summary(approval_handoff))
    |> maybe_put(
      :decision,
      decision_summary(normalized.permission_decision || normalized.decision)
    )
    |> maybe_put(:error, error_summary(response))
  end

  defp error_result(call, reason) do
    %{
      ok: false,
      status: "error",
      tool: call.name,
      tool_call_id: call.id,
      message: "coding tool failed: #{inspect(Redactor.redact(reason), limit: 40)}",
      error: inspect(Redactor.redact(reason), limit: 40),
      requested_args: Redactor.redact(call.arguments || %{}),
      actions: [
        %{
          name: call.name,
          status: :error,
          error: inspect(Redactor.redact(reason), limit: 40)
        }
      ]
    }
  end

  defp runner_context(name, args, context) do
    request = field(context, :request) || %{}
    metadata = field(request, :metadata) || field(context, :metadata) || %{}
    coding = field(metadata, :coding) || field(request, :coding) || field(context, :coding) || %{}

    context
    |> Map.put(:request, request)
    |> Map.put(:coding, coding)
    |> maybe_put(:channel, field(context, :channel) || field(request, :channel))
    |> maybe_put(:surface, field(context, :surface) || field(metadata, :surface) || "pi_mode")
    |> maybe_put(:session, field(context, :session) || field(request, :session) || %{main?: true})
    |> maybe_put(:operator_id, field(context, :operator_id) || field(request, :operator_id))
    |> maybe_put(:user_id, field(context, :user_id) || field(request, :user_id))
    |> Map.put(:selected_route, name)
    |> Map.put(:selected_action, name)
    |> Map.put(:source_text, source_text(name, args))
  end

  defp source_text(name, args) do
    args
    |> Redactor.redact()
    |> then(&"coding tool #{name} #{inspect(&1, limit: 40)}")
  end

  defp normalize_tool_call(%ReqLLM.ToolCall{} = tool_call) do
    tool_call
    |> ReqLLM.ToolCall.to_map()
    |> normalize_tool_call()
  end

  defp normalize_tool_call(tool_call) when is_map(tool_call) do
    %{
      id: field(tool_call, :id) || "call-#{System.unique_integer([:positive])}",
      name: field(tool_call, :name),
      arguments: arguments(field(tool_call, :arguments))
    }
  end

  defp normalize_tool_call(other) do
    %{
      id: "call-#{System.unique_integer([:positive])}",
      name: nil,
      arguments: %{invalid: inspect(other)}
    }
  end

  defp arguments(value) when is_map(value), do: value

  defp arguments(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _error -> %{"value" => value}
    end
  end

  defp arguments(nil), do: %{}
  defp arguments(other), do: %{"value" => inspect(other)}

  defp call_fields(call),
    do: %{tool_call_id: call.id, tool: call.name, requested_args: call.arguments}

  defp summarize_actions(actions) when is_list(actions) do
    Enum.map(actions, fn action ->
      %{
        name: field(action, :name),
        status: field(action, :status),
        permission: field(action, :permission),
        denial_reason: field(action, :denial_reason),
        execution: field(action, :execution),
        confirmation_id: field(action, :confirmation_id)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  defp approval_summary(nil), do: nil

  defp approval_summary(approval) when is_map(approval) do
    %{
      id: field(approval, :id),
      target: field(approval, :target),
      action: field(approval, :action)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp approval_summary(_approval), do: nil

  defp approval_handoff(%{status: :needs_confirmation} = response, context) do
    response
    |> Map.get(:permission_decision)
    |> ApprovalHandoff.pending(response, context)
    |> ApprovalHandoff.to_map()
  end

  defp approval_handoff(response, _context), do: field(response, :approval_handoff)

  defp decision_summary(nil), do: nil

  defp decision_summary(decision) when is_map(decision) do
    %{
      decision: field(decision, :decision),
      requires_confirmation: field(decision, :requires_confirmation),
      permission: field(decision, :permission)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp decision_summary(_decision), do: nil

  defp error_summary(%{error: nil}), do: nil
  defp error_summary(%{error: error}), do: inspect(Redactor.redact(error), limit: 40)
  defp error_summary(_response), do: nil

  defp bound(text, max_bytes) when is_binary(text) and byte_size(text) <= max_bytes, do: text

  defp bound(text, max_bytes) when is_binary(text) do
    binary_part(text, 0, max_bytes) <> "...[truncated]"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp field(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp field(_map, _key), do: nil
end
