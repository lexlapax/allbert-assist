defmodule AllbertAssist.Trace do
  @moduledoc """
  Markdown trace recorder for v0.01 runtime turns.

  M6 keeps traces plain and inspectable. The trace store writes markdown through
  `AllbertAssist.Memory` so the user can read, move, or delete trace files with
  ordinary filesystem tools.
  """

  alias AllbertAssist.Memory

  @model_alias :local

  @type result :: {:ok, Memory.entry()} | {:disabled, :tracing_disabled} | {:error, term()}

  @doc "Return true when runtime trace recording is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    config_enabled?() || env_enabled?()
  end

  @doc "Record one runtime turn as markdown when tracing is enabled."
  @spec record_turn(map()) :: result()
  def record_turn(turn) when is_map(turn) do
    if enabled?() do
      do_record_turn(turn)
    else
      {:disabled, :tracing_disabled}
    end
  end

  def record_turn(_turn), do: {:error, :invalid_trace_turn}

  defp do_record_turn(turn) do
    writer().(trace_attrs(turn))
  rescue
    exception ->
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp writer do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:writer, &Memory.append/1)
  end

  defp config_enabled? do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, false)
  end

  defp env_enabled? do
    System.get_env("ALLBERT_TRACE_ENABLED") in ["1", "true", "TRUE", "yes", "YES", "on", "ON"]
  end

  defp trace_attrs(turn) do
    response = Map.fetch!(turn, :response)
    input_signal = Map.fetch!(turn, :input_signal)
    response_signal = Map.fetch!(turn, :response_signal)
    request = Map.fetch!(turn, :request)

    %{
      category: :traces,
      summary: trace_summary(response, input_signal),
      body: trace_body(turn),
      source_signal_id: input_signal.id,
      actor: Map.get(request, :operator_id, "local"),
      agent: inspect(Map.get(turn, :agent, AllbertAssist.Agents.IntentAgent)),
      channel: Map.get(request, :channel, "unknown"),
      response_signal_id: response_signal.id
    }
  end

  defp trace_summary(response, input_signal) do
    action_name =
      response
      |> Map.get(:actions, [])
      |> List.first()
      |> action_name()

    "#{response.status} #{action_name} #{input_signal.id}"
  end

  defp trace_body(turn) do
    request = Map.fetch!(turn, :request)
    input_signal = Map.fetch!(turn, :input_signal)
    response_signal = Map.fetch!(turn, :response_signal)
    response = Map.fetch!(turn, :response)

    """
    ## Runtime Turn

    - Trace format: v0.01-m6
    - Input signal: #{input_signal.id}
    - Input signal type: #{input_signal.type}
    - Response signal: #{response_signal.id}
    - Response signal type: #{response_signal.type}
    - Channel: #{request.channel}
    - Operator: #{request.operator_id}
    - Agent: #{inspect(Map.get(turn, :agent, AllbertAssist.Agents.IntentAgent))}
    - Model alias: #{model_alias()}
    - Status: #{response.status}
    - Selected action: #{selected_action(response.actions)}
    - Permission decision: #{permission_decision(response.actions)}
    - Token estimate: #{token_estimate(request.text, response.message)}
    - Cost estimate: unavailable-local-model

    ## Input

    #{request.text}

    ## Response

    #{response.message}

    ## Actions

    ```elixir
    #{inspect(response.actions, pretty: true, limit: :infinity)}
    ```

    ## Diagnostics

    #{diagnostics_text(response)}
    """
    |> String.trim()
  end

  defp model_alias do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:model_alias, @model_alias)
  end

  defp selected_action(actions) do
    actions
    |> List.first()
    |> action_name()
  end

  defp action_name(%{name: name}) when is_binary(name), do: name
  defp action_name(%{"name" => name}) when is_binary(name), do: name
  defp action_name(_action), do: "none"

  defp permission_decision(actions) do
    actions
    |> List.first()
    |> case do
      %{permission_decision: decision} -> inspect(decision, pretty: true)
      %{"permission_decision" => decision} -> inspect(decision, pretty: true)
      _action -> "none"
    end
  end

  defp token_estimate(input, output) do
    [input, output]
    |> Enum.map(&estimate_text_tokens/1)
    |> Enum.sum()
  end

  defp estimate_text_tokens(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp estimate_text_tokens(_text), do: 0

  defp diagnostics_text(%{diagnostics: []}), do: "none"
  defp diagnostics_text(%{diagnostics: diagnostics}), do: inspect(diagnostics, pretty: true)
  defp diagnostics_text(_response), do: "none"
end
