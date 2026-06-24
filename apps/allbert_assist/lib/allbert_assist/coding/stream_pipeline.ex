defmodule AllbertAssist.Coding.StreamPipeline do
  @moduledoc """
  Converts ReqLLM streaming chunks into the v0.57 coding stream-event contract.

  This module is rendering/transport substrate only. It consumes provider-neutral
  chunks and emits validated `Coding.StreamEvent` maps; turn supervision,
  cancellation, and action execution stay in later milestones and the existing
  runner/security boundaries.
  """

  alias AllbertAssist.Coding.StreamEvent
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Runtime.Response

  @type emit_fun :: (StreamEvent.t() -> term())

  @doc "Convert an enumerable of `ReqLLM.StreamChunk` structs/maps into stream events."
  @spec events_from_chunks(Enumerable.t(), keyword()) ::
          {:ok, [StreamEvent.t()]} | {:error, term()}
  def events_from_chunks(chunks, opts) do
    turn_id = Keyword.fetch!(opts, :turn_id)
    start_sequence = Keyword.get(opts, :start_sequence, 0)

    chunks
    |> Enum.with_index(start_sequence)
    |> Enum.reduce_while({:ok, []}, fn {chunk, sequence}, {:ok, events} ->
      case event_from_chunk(chunk, turn_id, sequence) do
        {:ok, nil} -> {:cont, {:ok, events}}
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Consume a ReqLLM stream response once and invoke `emit_fun` for every stream event."
  @spec emit_stream_response(map(), keyword(), emit_fun()) ::
          {:ok, [StreamEvent.t()]} | {:error, term()}
  def emit_stream_response(%ReqLLM.StreamResponse{stream: stream}, opts, emit_fun)
      when is_function(emit_fun, 1) do
    turn_id = Keyword.fetch!(opts, :turn_id)
    start_sequence = Keyword.get(opts, :start_sequence, 0)

    stream
    |> Enum.reduce_while({:ok, start_sequence, []}, fn chunk, {:ok, sequence, events} ->
      case event_from_chunk(chunk, turn_id, sequence) do
        {:ok, nil} ->
          {:cont, {:ok, sequence + 1, events}}

        {:ok, event} ->
          emit_fun.(event)
          {:cont, {:ok, sequence + 1, [event | events]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _sequence, events} -> {:ok, Enum.reverse(events)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Build the final turn-complete event from a runtime response-like value."
  @spec turn_complete_event(map(), keyword()) :: {:ok, StreamEvent.t()} | {:error, term()}
  def turn_complete_event(response, opts) when is_map(response) do
    turn_id = Keyword.fetch!(opts, :turn_id)
    sequence = Keyword.get(opts, :sequence)
    normalized = Response.normalize(response)

    attrs =
      %{
        turn_id: turn_id,
        model_payload: normalized.model_payload,
        surface_payload: normalized.surface_payload,
        metadata: %{
          status: normalized.status,
          actions_count: length(normalized.actions)
        }
      }
      |> maybe_put(:sequence, sequence)

    StreamEvent.new(:turn_complete, attrs)
  end

  @doc "Convert one provider stream chunk into a stream event, or nil for metadata-only chunks."
  @spec event_from_chunk(term(), String.t(), non_neg_integer()) ::
          {:ok, StreamEvent.t() | nil} | {:error, term()}
  def event_from_chunk(%ReqLLM.StreamChunk{type: :content} = chunk, turn_id, sequence) do
    StreamEvent.new(:assistant_token_delta, %{
      turn_id: turn_id,
      sequence: sequence,
      text: Redactor.redact(chunk.text || ""),
      metadata: chunk.metadata || %{}
    })
  end

  def event_from_chunk(%ReqLLM.StreamChunk{type: :thinking} = chunk, turn_id, sequence) do
    StreamEvent.new(:assistant_token_delta, %{
      turn_id: turn_id,
      sequence: sequence,
      text: Redactor.redact(chunk.text || ""),
      metadata: Map.put(chunk.metadata || %{}, :kind, :thinking)
    })
  end

  def event_from_chunk(%ReqLLM.StreamChunk{type: :tool_call} = chunk, turn_id, sequence) do
    StreamEvent.new(:tool_call_argument_delta, %{
      turn_id: turn_id,
      sequence: sequence,
      tool_call_id: tool_call_id(chunk, sequence),
      tool_name: chunk.name,
      arguments_delta: Redactor.redact(chunk.arguments || %{}),
      metadata: chunk.metadata || %{}
    })
  end

  def event_from_chunk(%ReqLLM.StreamChunk{type: :meta}, _turn_id, _sequence), do: {:ok, nil}

  def event_from_chunk(%ReqLLM.StreamChunk{type: other}, _turn_id, _sequence),
    do: {:error, {:unsupported_stream_chunk_type, other}}

  def event_from_chunk(%{type: _type} = chunk, turn_id, sequence) do
    chunk
    |> struct_from_map()
    |> event_from_chunk(turn_id, sequence)
  end

  def event_from_chunk(_chunk, _turn_id, _sequence), do: {:error, :invalid_stream_chunk}

  defp struct_from_map(chunk) do
    %ReqLLM.StreamChunk{
      type: field(chunk, :type),
      text: field(chunk, :text),
      name: field(chunk, :name),
      arguments: field(chunk, :arguments),
      metadata: field(chunk, :metadata) || %{}
    }
  end

  defp tool_call_id(%ReqLLM.StreamChunk{metadata: metadata, name: name}, sequence) do
    field(metadata || %{}, :id) ||
      field(metadata || %{}, :tool_call_id) ||
      "#{name || "tool"}-#{sequence}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
