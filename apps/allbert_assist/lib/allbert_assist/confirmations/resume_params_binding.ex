defmodule AllbertAssist.Confirmations.ResumeParamsBinding do
  @moduledoc """
  Produces the durable content binding for a confirmation's resume packet.

  Registered actions may normalize their original parameters before asking for
  confirmation. This binding preserves that action-owned packet without making
  it equivalent to the grounded Objective step that caused the action to run.
  """

  @domain "allbert.confirmation.resume-params.v1\0"
  @digest_pattern ~r/\A[0-9a-f]{64}\z/

  @doc "Return a deterministic SHA-256 binding for JSON-compatible resume params."
  @spec digest(map()) :: {:ok, String.t()} | {:error, :invalid_confirmation_resume_params}
  def digest(%{} = params) do
    with {:ok, canonical_json} <- canonical_json(params) do
      digest =
        :sha256
        |> :crypto.hash(@domain <> canonical_json)
        |> Base.encode16(case: :lower)

      {:ok, digest}
    end
  end

  def digest(_params), do: {:error, :invalid_confirmation_resume_params}

  @doc "Verify resume params against a previously persisted binding."
  @spec verify(String.t() | nil, map()) ::
          :ok
          | {:error,
             :confirmation_resume_params_unbound
             | :confirmation_resume_params_mismatch
             | :invalid_confirmation_resume_params}
  def verify(nil, _params), do: {:error, :confirmation_resume_params_unbound}

  def verify(expected, %{} = params) when is_binary(expected) do
    with true <- valid_digest?(expected),
         {:ok, actual} <- digest(params),
         true <- actual == expected do
      :ok
    else
      false -> {:error, :confirmation_resume_params_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_expected, _params), do: {:error, :invalid_confirmation_resume_params}

  @doc false
  @spec valid_digest?(term()) :: boolean()
  def valid_digest?(value), do: is_binary(value) and Regex.match?(@digest_pattern, value)

  defp canonical_json(value) do
    value
    |> stringify()
    |> encode_json()
  rescue
    Protocol.UndefinedError -> {:error, :invalid_confirmation_resume_params}
    Jason.EncodeError -> {:error, :invalid_confirmation_resume_params}
    ArgumentError -> {:error, :invalid_confirmation_resume_params}
  end

  defp stringify(map) when is_map(map) do
    normalized = Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

    if map_size(normalized) == map_size(map),
      do: normalized,
      else: raise(ArgumentError, "duplicate normalized JSON key")
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  defp stringify(value), do: value

  defp encode_json(map) when is_map(map) do
    encoded =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> encoded_json!(value)
      end)

    {:ok, "{" <> encoded <> "}"}
  end

  defp encoded_json!(map) when is_map(map) do
    {:ok, encoded} = encode_json(map)
    encoded
  end

  defp encoded_json!(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &encoded_json!/1) <> "]"

  defp encoded_json!(value), do: Jason.encode!(value)
end
