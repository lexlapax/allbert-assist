defmodule StockSage.Bridge.Protocol do
  @moduledoc """
  JSON-over-stdio protocol envelope for the StockSage Python bridge.

  ADR 0020 defines the wire format. This module owns encode, decode, and
  action validation. It contains no Port or process logic.
  """

  @valid_actions ~w(ping run_analysis)
  @max_reason_chars 500

  @typedoc "Request map accepted by encode_request/1."
  @type request :: %{
          required(:id) => String.t(),
          required(:action) => String.t(),
          optional(any) => any
        }

  @typedoc "Response map produced by decode_response/1."
  @type response :: %{required(String.t()) => any}

  @doc "Encode a request map as a newline-terminated JSON binary."
  @spec encode_request(map()) :: {:ok, binary()} | {:error, term()}
  def encode_request(%{} = request) do
    with {:ok, id} <- require_field(request, :id, :missing_id),
         {:ok, action} <- require_field(request, :action, :missing_action),
         true <- valid_action?(action) || {:error, {:unknown_action, action}},
         payload <- request |> normalize_payload() |> Map.merge(%{"id" => id, "action" => action}),
         {:ok, json} <- safe_encode(payload) do
      {:ok, json <> "\n"}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :unknown_action}
    end
  end

  def encode_request(_other), do: {:error, :invalid_request}

  @doc "Decode a single JSON line from the bridge."
  @spec decode_response(binary()) :: {:ok, map()} | {:error, term()}
  def decode_response(line) when is_binary(line) do
    line
    |> String.trim()
    |> case do
      "" ->
        {:error, :empty_response}

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, %{} = decoded} ->
            validate_response(decoded)

          {:ok, _other} ->
            {:error, :invalid_response_shape}

          {:error, %Jason.DecodeError{} = err} ->
            {:error, {:invalid_json, Exception.message(err)}}
        end
    end
  end

  def decode_response(_other), do: {:error, :invalid_response}

  @doc "Return true when the action is recognized by the bridge protocol."
  @spec valid_action?(any()) :: boolean()
  def valid_action?(action) when is_binary(action), do: action in @valid_actions
  def valid_action?(_action), do: false

  @doc "Bound an error reason string for inclusion in error responses or signals."
  @spec bounded_reason(any()) :: String.t()
  def bounded_reason(reason) when is_binary(reason),
    do: reason |> String.slice(0, @max_reason_chars)

  def bounded_reason(reason), do: reason |> inspect() |> bounded_reason()

  defp validate_response(%{"id" => id, "status" => status} = response)
       when is_binary(id) and status in ["ok", "error"] do
    {:ok, response}
  end

  defp validate_response(_response), do: {:error, :invalid_response_shape}

  defp normalize_payload(request) do
    request
    |> Enum.map(fn {key, value} -> {to_string_key(key), value} end)
    |> Map.new()
  end

  defp to_string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_string_key(key) when is_binary(key), do: key
  defp to_string_key(key), do: to_string(key)

  defp require_field(map, key, error) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, error}
    end
  end

  defp safe_encode(payload) do
    Jason.encode(payload)
  rescue
    exception -> {:error, {:encode_failed, Exception.message(exception)}}
  end
end
