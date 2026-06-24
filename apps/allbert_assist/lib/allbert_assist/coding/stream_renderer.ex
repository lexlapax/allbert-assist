defmodule AllbertAssist.Coding.StreamRenderer do
  @moduledoc """
  Pure renderer/state machine for v0.57 coding stream events.

  The renderer accumulates assistant token deltas, progressive tool-call argument
  deltas, tool-result deltas, cancellation, and final turn-complete payloads. It
  grants no authority and never feeds `surface_payload` back into model context.
  """

  alias AllbertAssist.Coding.StreamEvent
  alias AllbertAssist.Runtime.Redactor

  @default_max_text_bytes 12_000

  @type tool_call_state :: %{
          required(:id) => String.t(),
          optional(:name) => String.t(),
          optional(:arguments) => term(),
          optional(:complete?) => boolean()
        }

  @type t :: %{
          required(:turn_id) => String.t(),
          required(:assistant_text) => String.t(),
          required(:tool_calls) => %{optional(String.t()) => tool_call_state()},
          required(:tool_results) => [String.t()],
          required(:cancelled?) => boolean(),
          required(:complete?) => boolean(),
          optional(:model_payload) => String.t(),
          optional(:surface_payload) => String.t(),
          optional(:cancel_reason) => term()
        }

  @doc "Create an empty stream-render state for a turn."
  @spec new(String.t()) :: t()
  def new(turn_id) when is_binary(turn_id) and turn_id != "" do
    %{
      turn_id: turn_id,
      assistant_text: "",
      tool_calls: %{},
      tool_results: [],
      cancelled?: false,
      complete?: false
    }
  end

  @doc "Apply one validated or validate-able stream event to the renderer state."
  @spec apply_event(t(), map()) :: {:ok, t()} | {:error, term()}
  def apply_event(state, event) when is_map(state) and is_map(event) do
    with {:ok, event} <- StreamEvent.validate(event),
         :ok <- same_turn?(state, event) do
      {:ok, do_apply_event(state, event)}
    end
  end

  @doc "Apply events in order."
  @spec apply_events(t(), Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def apply_events(state, events) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, state} ->
      case apply_event(state, event) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Render a state to terminal-safe text."
  @spec render(t(), keyword()) :: String.t()
  def render(state, opts \\ []) do
    max_text_bytes = Keyword.get(opts, :max_text_bytes, @default_max_text_bytes)

    state
    |> render_text()
    |> Redactor.redact()
    |> bound_text(max_text_bytes)
  end

  @doc "Convenience: apply and render stream events from an empty state."
  @spec render_events(Enumerable.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def render_events(events, opts) do
    turn_id = Keyword.fetch!(opts, :turn_id)

    with {:ok, state} <- apply_events(new(turn_id), events) do
      {:ok, render(state, opts)}
    end
  end

  defp same_turn?(%{turn_id: turn_id}, %{turn_id: turn_id}), do: :ok
  defp same_turn?(_state, event), do: {:error, {:wrong_turn_id, Map.get(event, :turn_id)}}

  defp do_apply_event(state, %{type: :assistant_token_delta, text: text}) do
    Map.update!(state, :assistant_text, &(&1 <> Redactor.redact(text)))
  end

  defp do_apply_event(state, %{type: :tool_call_argument_delta} = event) do
    id = Map.get(event, :tool_call_id) || "tool-call"
    delta = Map.get(event, :arguments_delta)

    Map.update!(state, :tool_calls, fn tool_calls ->
      Map.update(tool_calls, id, new_tool_call(id, event, delta), fn existing ->
        existing
        |> maybe_put(:name, Map.get(event, :tool_name) || Map.get(existing, :name))
        |> Map.update(:arguments, delta, &merge_arguments(&1, delta))
      end)
    end)
  end

  defp do_apply_event(state, %{type: :tool_call_argument_complete} = event) do
    id = Map.get(event, :tool_call_id) || "tool-call"

    Map.update!(state, :tool_calls, fn tool_calls ->
      Map.update(tool_calls, id, %{id: id, complete?: true}, &Map.put(&1, :complete?, true))
    end)
  end

  defp do_apply_event(state, %{type: :tool_result_delta, text: text}) do
    Map.update!(state, :tool_results, &(&1 ++ [Redactor.redact(text)]))
  end

  defp do_apply_event(state, %{type: :turn_cancelled} = event) do
    state
    |> Map.put(:cancelled?, true)
    |> Map.put(:cancel_reason, Map.get(event, :reason))
  end

  defp do_apply_event(state, %{type: :turn_complete} = event) do
    state
    |> Map.put(:complete?, true)
    |> maybe_put(:model_payload, Map.get(event, :model_payload))
    |> maybe_put(:surface_payload, Map.get(event, :surface_payload))
  end

  defp render_text(%{complete?: true, surface_payload: payload}) when is_binary(payload) do
    payload
  end

  defp render_text(state) do
    [
      assistant_section(state.assistant_text),
      tool_section(state.tool_calls),
      result_section(state.tool_results),
      cancelled_section(state)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp assistant_section(""), do: nil
  defp assistant_section(text), do: text

  defp tool_section(tool_calls) when map_size(tool_calls) == 0, do: nil

  defp tool_section(tool_calls) do
    tool_calls
    |> Enum.sort_by(fn {id, _tool} -> id end)
    |> Enum.map_join("\n\n", fn {_id, tool} ->
      label =
        case Map.get(tool, :name) do
          nil -> "Tool call #{tool.id}"
          name -> "Tool call #{name}"
        end

      [label, render_arguments(Map.get(tool, :arguments))]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n")
    end)
  end

  defp result_section([]), do: nil
  defp result_section(results), do: Enum.join(results, "\n")

  defp cancelled_section(%{cancelled?: true, cancel_reason: reason}),
    do: "Turn cancelled: #{inspect(Redactor.redact(reason))}"

  defp cancelled_section(_state), do: nil

  defp new_tool_call(id, event, delta) do
    %{
      id: id,
      name: Map.get(event, :tool_name),
      arguments: delta,
      complete?: false
    }
  end

  defp merge_arguments(existing, delta) when is_binary(existing) and is_binary(delta),
    do: existing <> delta

  defp merge_arguments(existing, delta) when is_map(existing) and is_map(delta),
    do: Map.merge(existing, delta)

  defp merge_arguments(_existing, delta), do: delta

  defp render_arguments(nil), do: nil

  defp render_arguments("") do
    nil
  end

  defp render_arguments(arguments) when is_binary(arguments), do: arguments

  defp render_arguments(arguments) do
    case Jason.encode(arguments, pretty: true) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(arguments, pretty: true)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp bound_text(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp bound_text(text, max_bytes) do
    text
    |> binary_part(0, max_bytes)
    |> String.trim_trailing()
    |> Kernel.<>("...")
  end

  defp blank?(value), do: value in [nil, ""]
end
