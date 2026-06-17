defmodule AllbertAssist.Intent.Slots do
  @moduledoc """
  Canonical normalization for intent **slots** — the single seam where
  (possibly degraded) model output becomes action parameters.

  Slots arrive from two producers that previously each coerced and key-mapped
  them independently:

    * the two-stage router (`Outcome` slots from the disambiguator), and
    * the deterministic engine (`Decision` `trace_metadata.extracted_slots`).

  Both now funnel through this module so a malformed payload (a list/scalar or
  unparseable JSON from a timed-out / partial model decode) degrades to
  "no slots" uniformly instead of crashing the execute path. Routing grants no
  authority: this only shapes params; the action's own permission/confirmation
  gate is unchanged.

  Key policy differs by producer and is preserved explicitly:

    * `:existing_atom` (router policy) — keep only keys that resolve to an
      existing atom; **drop** unknown keys. Slot values use `Map.put_new/3`
      (never overwrite a param the caller already set).
    * `:lenient` (engine policy) — keep unknown string keys as-is. Used when
      building a standalone descriptor-params map.
  """

  @type key_mode :: :existing_atom | :lenient

  @doc """
  Coerce an arbitrary slot payload to a map.

  A well-formed payload is already a map. A JSON string is decoded (and must
  itself decode to a map). Anything else — a list, scalar, empty/garbage
  string, or `nil` — becomes `%{}`.
  """
  @spec normalize(term()) :: map()
  def normalize(slots) when is_map(slots), do: slots

  def normalize(slots) when is_binary(slots) and slots != "" do
    case Jason.decode(slots) do
      {:ok, map} when is_map(map) -> map
      _other -> %{}
    end
  end

  def normalize(_slots), do: %{}

  @doc """
  Normalize a payload into a standalone params map under `key_mode`.

  Equivalent to merging into an empty map; used by the engine path to build the
  descriptor-params map the caller then merges into the base params.
  """
  @spec to_params(term(), key_mode()) :: map()
  def to_params(slots, key_mode \\ :lenient), do: merge(%{}, slots, key_mode: key_mode, overwrite: true)

  @doc """
  Merge a (normalized) slot payload into `params`.

  Options:

    * `:key_mode` — `:existing_atom` (default) or `:lenient`, see moduledoc.
    * `:overwrite` — when `true`, slot values replace existing params; when
      `false` (default), existing params win (`Map.put_new/3`).
  """
  @spec merge(map(), term(), keyword()) :: map()
  def merge(params, slots, opts \\ []) when is_map(params) do
    key_mode = Keyword.get(opts, :key_mode, :existing_atom)
    overwrite? = Keyword.get(opts, :overwrite, false)

    slots
    |> normalize()
    |> Enum.reduce(params, fn {key, value}, acc ->
      case normalize_key(key, key_mode) do
        :drop -> acc
        {:ok, normalized_key} -> put_slot(acc, normalized_key, value, overwrite?)
      end
    end)
  end

  @doc """
  Resolve a slot key under `key_mode`.

  Returns `{:ok, key}` with an atom (or, in `:lenient` mode, the original
  string when no atom exists) or `:drop` to discard the key.
  """
  @spec normalize_key(term(), key_mode()) :: {:ok, atom() | String.t()} | :drop
  def normalize_key(key, _mode) when is_atom(key), do: {:ok, key}

  def normalize_key(key, mode) when is_binary(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> if mode == :lenient, do: {:ok, key}, else: :drop
  end

  def normalize_key(_key, _mode), do: :drop

  defp put_slot(params, key, value, true), do: Map.put(params, key, value)
  defp put_slot(params, key, value, false), do: Map.put_new(params, key, value)
end
