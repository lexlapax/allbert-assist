defmodule AllbertAssist.Tools.ToolCandidate do
  @moduledoc """
  Normalized discovery result shared by local and remote tool-source adapters.

  A candidate is descriptive metadata. Remote MCP candidates are always inert
  until the `mcp_server_connect` confirmation gate persists a configured server.
  """

  @type source :: :local_action | :local_skill | :configured_mcp | :remote_mcp
  @type requirement :: :none | :connect_confirmation

  @enforce_keys [:id, :name, :description, :source, :usable_now?, :requires]
  defstruct [
    :id,
    :name,
    :description,
    :source,
    :usable_now?,
    :requires,
    provenance: %{},
    signals: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          source: source(),
          usable_now?: boolean(),
          requires: requirement(),
          provenance: map(),
          signals: map()
        }

  @sources [:local_action, :local_skill, :configured_mcp, :remote_mcp]

  @doc "Normalize adapter output into a `ToolCandidate`."
  @spec normalize(map()) :: {:ok, t()} | {:error, term()}
  def normalize(attrs) when is_map(attrs) do
    with {:ok, source} <- normalize_source(field(attrs, :source)),
         {:ok, name} <- normalize_name(field(attrs, :name)),
         {:ok, description} <- normalize_description(field(attrs, :description, "")),
         {:ok, provenance} <- normalize_map(field(attrs, :provenance, %{}), :provenance),
         {:ok, signals} <- normalize_map(field(attrs, :signals, %{}), :signals),
         {:ok, id} <- normalize_id(field(attrs, :id), source, name, provenance, signals) do
      {usable_now?, requires} = access_contract(source)

      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         description: description,
         source: source,
         usable_now?: usable_now?,
         requires: requires,
         provenance: provenance,
         signals: signals
       }}
    end
  end

  def normalize(attrs), do: {:error, {:expected_map, attrs}}

  @doc "Normalize a list of adapter outputs, failing on the first invalid entry."
  @spec normalize_many([map()]) :: {:ok, [t()]} | {:error, term()}
  def normalize_many(attrs_list) when is_list(attrs_list) do
    Enum.reduce_while(attrs_list, {:ok, []}, fn attrs, {:ok, acc} ->
      case normalize(attrs) do
        {:ok, candidate} -> {:cont, {:ok, [candidate | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
      error -> error
    end
  end

  def normalize_many(value), do: {:error, {:expected_list, value}}

  @doc "Return a map suited for JSON encoding and persistence boundaries."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = candidate) do
    %{
      id: candidate.id,
      name: candidate.name,
      description: candidate.description,
      source: candidate.source,
      usable_now?: candidate.usable_now?,
      requires: candidate.requires,
      provenance: candidate.provenance,
      signals: candidate.signals
    }
  end

  defp field(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp normalize_source(source) when source in @sources, do: {:ok, source}

  defp normalize_source(source) when is_binary(source) do
    source
    |> String.trim()
    |> String.replace("-", "_")
    |> String.to_existing_atom()
    |> normalize_source()
  rescue
    ArgumentError -> {:error, {:invalid_source, source}}
  end

  defp normalize_source(source), do: {:error, {:invalid_source, source}}

  defp normalize_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :missing_name}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_name(name), do: {:error, {:invalid_name, name}}

  defp normalize_description(nil), do: {:ok, ""}

  defp normalize_description(description) when is_binary(description) do
    {:ok, String.trim(description)}
  end

  defp normalize_description(description), do: {:error, {:invalid_description, description}}

  defp normalize_map(nil, _field), do: {:ok, %{}}
  defp normalize_map(value, _field) when is_map(value), do: {:ok, value}
  defp normalize_map(value, field), do: {:error, {:invalid_map, field, value}}

  defp normalize_id(nil, source, name, provenance, signals) do
    {:ok, stable_id(source, name, provenance, signals)}
  end

  defp normalize_id(id, _source, _name, _provenance, _signals) when is_binary(id) do
    case String.trim(id) do
      "" -> {:error, :missing_id}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_id(id, _source, _name, _provenance, _signals),
    do: {:error, {:invalid_id, id}}

  defp access_contract(:remote_mcp), do: {false, :connect_confirmation}
  defp access_contract(_source), do: {true, :none}

  defp stable_id(source, name, provenance, signals) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_.-]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "tool"
        value -> value
      end

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({source, name, provenance, signals}))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "#{source}:#{slug}:#{digest}"
  end
end
