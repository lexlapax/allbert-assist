defmodule AllbertAssist.Coding.StreamEvent do
  @moduledoc """
  v0.57 Pi-mode stream-event contract.

  M0 defines the vocabulary and transport-safe shape. Later milestones wire
  ReqLLM streaming, live rendering, supervised turns, and cancellation to these
  events.
  """

  @types [
    :assistant_token_delta,
    :tool_call_argument_delta,
    :tool_call_argument_complete,
    :tool_result_delta,
    :turn_cancelled,
    :turn_complete
  ]

  @type event_type ::
          :assistant_token_delta
          | :tool_call_argument_delta
          | :tool_call_argument_complete
          | :tool_result_delta
          | :turn_cancelled
          | :turn_complete

  @type t :: %{
          required(:type) => event_type(),
          required(:turn_id) => String.t(),
          optional(:sequence) => non_neg_integer(),
          optional(:text) => String.t(),
          optional(:tool_call_id) => String.t(),
          optional(:tool_name) => String.t(),
          optional(:arguments_delta) => String.t() | map(),
          optional(:model_payload) => String.t(),
          optional(:surface_payload) => String.t(),
          optional(:reason) => term(),
          optional(:metadata) => map()
        }

  @doc "Return the stream-event vocabulary in wire order."
  @spec types() :: nonempty_list(event_type())
  def types, do: @types

  @doc "Build and validate a stream event."
  @spec new(event_type(), map()) :: {:ok, t()} | {:error, term()}
  def new(type, attrs) when type in @types and is_map(attrs) do
    event =
      attrs
      |> normalize_attrs()
      |> Map.put(:type, type)

    with :ok <- require_turn_id(event),
         :ok <- validate_type_payload(event) do
      {:ok, event}
    end
  end

  def new(type, _attrs), do: {:error, {:unknown_stream_event_type, type}}

  @doc "Validate an existing event map."
  @spec validate(map()) :: {:ok, t()} | {:error, term()}
  def validate(%{type: type} = event) when type in @types do
    new(type, Map.delete(event, :type))
  end

  def validate(%{"type" => type} = event) when is_binary(type) do
    type
    |> String.to_existing_atom()
    |> new(Map.delete(event, "type"))
  rescue
    ArgumentError -> {:error, {:unknown_stream_event_type, type}}
  end

  def validate(%{} = event), do: {:error, {:missing_stream_event_type, event}}

  def validate(other), do: {:error, {:invalid_stream_event, other}}

  defp normalize_attrs(attrs) do
    attrs
    |> Enum.map(fn {key, value} -> {normalize_key(key), value} end)
    |> Map.new()
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    key
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> key
  end

  defp require_turn_id(%{turn_id: turn_id}) when is_binary(turn_id) and turn_id != "", do: :ok
  defp require_turn_id(event), do: {:error, {:missing_turn_id, event}}

  defp validate_type_payload(%{type: :assistant_token_delta, text: text}) when is_binary(text),
    do: :ok

  defp validate_type_payload(%{type: :tool_call_argument_delta, arguments_delta: _delta}),
    do: :ok

  defp validate_type_payload(%{type: :tool_call_argument_complete}), do: :ok

  defp validate_type_payload(%{type: :tool_result_delta, text: text}) when is_binary(text),
    do: :ok

  defp validate_type_payload(%{type: :turn_cancelled}), do: :ok

  defp validate_type_payload(%{type: :turn_complete}), do: :ok

  defp validate_type_payload(event), do: {:error, {:invalid_stream_event_payload, event}}
end
