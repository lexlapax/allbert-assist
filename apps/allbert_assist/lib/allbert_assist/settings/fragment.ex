defmodule AllbertAssist.Settings.Fragment do
  @moduledoc """
  Declarative settings schema fragment.

  Fragments let core contexts, reviewed apps, and reviewed plugins own the
  schema rows they contribute while Settings Central remains the only write
  authority.
  """

  @enforce_keys [:id, :owner, :source, :schema]
  defstruct [
    :id,
    :owner,
    :source,
    :group,
    schema_version: 1,
    schema: %{},
    defaults: %{},
    safe_write_keys: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: term(),
          owner: term(),
          source: :core | :app | :plugin,
          group: atom() | String.t() | nil,
          schema_version: pos_integer(),
          schema: %{String.t() => map()},
          defaults: map(),
          safe_write_keys: [String.t()],
          metadata: map()
        }

  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    schema = Map.fetch!(attrs, :schema)

    unless is_map(schema) and Enum.all?(schema, &valid_schema_entry?/1) do
      raise ArgumentError, "settings fragment schema must be a map of binary keys to maps"
    end

    schema_version =
      attrs
      |> Map.get(:schema_version, version_from_schema(schema))
      |> validate_schema_version!()

    attrs =
      attrs
      |> Map.put(:schema_version, schema_version)

    struct!(__MODULE__, attrs)
  end

  defp valid_schema_entry?({key, value}), do: is_binary(key) and is_map(value)

  defp version_from_schema(schema) do
    schema
    |> Enum.flat_map(fn
      {key, entry} when is_binary(key) and is_map(entry) ->
        version = Map.get(entry, :default, Map.get(entry, "default"))

        if schema_version_key?(key), do: [version], else: []

      _entry ->
        []
    end)
    |> Enum.filter(&positive_integer?/1)
    |> case do
      [] -> 1
      versions -> Enum.max(versions)
    end
  end

  defp schema_version_key?(key), do: String.ends_with?(key, ".schema_version")

  defp validate_schema_version!(version) when is_integer(version) and version > 0, do: version

  defp validate_schema_version!(version) do
    raise ArgumentError,
          "settings fragment schema_version must be a positive integer, got: #{inspect(version)}"
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
