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

    struct!(__MODULE__, attrs)
  end

  defp valid_schema_entry?({key, value}), do: is_binary(key) and is_map(value)
end
