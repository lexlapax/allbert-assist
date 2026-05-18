defmodule AllbertAssist.Workspace.Fragment.Envelope do
  @moduledoc """
  Signed provenance wrapper for workspace runtime fragments.

  M2 implements shape normalization plus HMAC signing and verification. The
  full emission validator chain lands in M7.
  """

  alias AllbertAssist.Surface

  defstruct [
    :id,
    :surface,
    :emitter_id,
    :user_id,
    :thread_id,
    :scope,
    :tile_position,
    :kind,
    :emitted_at,
    :signature,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          surface: Surface.t() | nil,
          emitter_id: String.t() | nil,
          user_id: String.t() | nil,
          thread_id: String.t() | nil,
          scope: String.t() | atom() | nil,
          tile_position: integer() | nil,
          kind: String.t() | atom() | nil,
          emitted_at: DateTime.t() | String.t() | nil,
          signature: String.t() | nil,
          metadata: map()
        }

  @required_fields [:surface, :emitter_id, :user_id, :thread_id, :scope, :kind, :emitted_at]
  @scopes ~w[canvas ephemeral]

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    envelope =
      attrs
      |> normalize_attrs()
      |> Map.put_new(:id, new_id())
      |> Map.put_new(:metadata, %{})
      |> Map.put_new(:emitted_at, DateTime.utc_now())
      |> then(&struct(__MODULE__, &1))

    with :ok <- validate_shape(envelope) do
      {:ok, envelope}
    end
  end

  def new(_attrs), do: {:error, :invalid_envelope}

  @spec sign(map() | t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def sign(attrs_or_envelope, secret) when is_binary(secret) and byte_size(secret) > 0 do
    with {:ok, envelope} <- coerce(attrs_or_envelope),
         :ok <- validate_shape(envelope) do
      {:ok, %{envelope | signature: signature(envelope, secret)}}
    end
  end

  def sign(_attrs_or_envelope, _secret), do: {:error, :invalid_secret}

  @spec verify(t(), String.t()) :: :ok | {:error, atom()}
  def verify(%__MODULE__{} = envelope, secret) when is_binary(secret) and byte_size(secret) > 0 do
    with :ok <- validate_shape(envelope),
         signature when is_binary(signature) <- envelope.signature do
      if :crypto.hash_equals(signature, signature(envelope, secret)) do
        :ok
      else
        {:error, :signature_invalid}
      end
    else
      nil -> {:error, :signature_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_envelope, _secret), do: {:error, :invalid_envelope}

  @spec validate_shape(t()) :: :ok | {:error, atom()}
  def validate_shape(%__MODULE__{} = envelope) do
    cond do
      Enum.any?(@required_fields, &(is_nil(Map.get(envelope, &1)) or Map.get(envelope, &1) == "")) ->
        {:error, :invalid_envelope}

      not match?(%Surface{}, envelope.surface) ->
        {:error, :invalid_surface}

      scope(envelope.scope) not in @scopes ->
        {:error, :invalid_scope}

      not is_map(envelope.metadata) ->
        {:error, :invalid_metadata}

      true ->
        :ok
    end
  end

  def validate_shape(_envelope), do: {:error, :invalid_envelope}

  defp coerce(%__MODULE__{} = envelope), do: {:ok, envelope}
  defp coerce(%{} = attrs), do: new(attrs)
  defp coerce(_attrs), do: {:error, :invalid_envelope}

  defp signature(%__MODULE__{} = envelope, secret) do
    :crypto.mac(:hmac, :sha256, secret, canonical_payload(envelope))
    |> Base.encode16(case: :lower)
  end

  defp canonical_payload(%__MODULE__{} = envelope) do
    envelope
    |> Map.from_struct()
    |> Map.delete(:signature)
    |> canonical()
    |> Jason.encode!()
  end

  defp canonical(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp canonical(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp canonical(%_struct{} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Map.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp canonical(value), do: value

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      pair -> pair
    end)
  end

  defp scope(scope) when is_atom(scope), do: Atom.to_string(scope)
  defp scope(scope) when is_binary(scope), do: scope
  defp scope(scope), do: to_string(scope)

  defp new_id, do: "frag_" <> Ecto.UUID.generate()
end
