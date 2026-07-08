defmodule AllbertAssist.Personas do
  @moduledoc """
  v0.63 M4 — the repo-maintained persona catalog (ADR 0075, `persona-model.md`).

  Personas are reviewed, seed-only presets: a declarative `priv/personas/<id>.yaml`
  catalog loaded here and applied — after explicit review/confirm — by the
  `apply_persona_profile` action. They grant no authority, enable no egress, lower no
  confirmation floor, connect no channel, and store no secret.

  Each persona is the 8-field seed envelope: `persona_id`, `label`, `settings_seeds`
  (written only through Settings Central over `@safe_write_keys`), `suggested_apps` /
  `suggested_channels` / `suggested_intents` (UI highlights, never writes),
  `model_purpose_map` (advice + a hosted-egress warning flag), and `first_chat_prompts`
  (starter prompts consumed at the `first_chat` step).

  The catalog is embedded at compile time (release-safe, no runtime file I/O);
  `validate!/0` re-checks the seed keys against the live safe-write set at boot.
  """

  alias AllbertAssist.Settings

  @envelope_keys ~w(persona_id label settings_seeds suggested_apps
                    suggested_channels suggested_intents model_purpose_map
                    first_chat_prompts)

  @personas_dir Path.expand("../../priv/personas", __DIR__)
  @external_resource Path.join(@personas_dir, "general.yaml")
  @external_resource Path.join(@personas_dir, "researcher.yaml")
  @external_resource Path.join(@personas_dir, "developer.yaml")
  @external_resource Path.join(@personas_dir, "writer.yaml")
  @external_resource Path.join(@personas_dir, "ops.yaml")

  # Fixed catalog order = QuickStart/Advanced selection order.
  @persona_ids ~w(general researcher developer writer ops)

  @catalog (for id <- ~w(general researcher developer writer ops), into: %{} do
              path = Path.join(Path.expand("../../priv/personas", __DIR__), "#{id}.yaml")
              {:ok, raw} = YamlElixir.read_from_file(path)
              {id, raw}
            end)

  @typedoc "A persona seed envelope (string-keyed, as loaded from the catalog)."
  @type persona :: %{optional(String.t()) => term()}

  @doc "All personas in catalog (selection) order."
  @spec all() :: [persona()]
  def all, do: Enum.map(@persona_ids, &Map.fetch!(@catalog, &1))

  @doc "The catalog persona ids, in selection order."
  @spec ids() :: [String.t()]
  def ids, do: @persona_ids

  @doc "Fetch one persona by id."
  @spec fetch(String.t()) :: {:ok, persona()} | :error
  def fetch(persona_id) when is_binary(persona_id), do: Map.fetch(@catalog, persona_id)

  @doc "Fetch one persona by id, or nil."
  @spec get(String.t()) :: persona() | nil
  def get(persona_id) when is_binary(persona_id), do: Map.get(@catalog, persona_id)

  @doc """
  Validate the whole catalog against the current schema. Raises on any structural
  problem, an unknown envelope key, or a `settings_seeds` key that is not a live
  `@safe_write_key`. Call at boot so a bad catalog fails fast rather than at apply.
  """
  @spec validate!() :: :ok
  def validate! do
    Enum.each(@persona_ids, fn id ->
      persona = Map.fetch!(@catalog, id)

      case validate(id, persona) do
        :ok -> :ok
        {:error, reason} -> raise ArgumentError, "invalid persona #{id}: #{inspect(reason)}"
      end
    end)

    :ok
  end

  @doc "Validate a single persona map. Returns `:ok` or `{:error, reason}`."
  @spec validate(String.t(), persona()) :: :ok | {:error, term()}
  def validate(id, persona) when is_map(persona) do
    with :ok <- check_id(id, persona),
         :ok <- check_label(persona),
         :ok <- check_no_unknown_keys(persona),
         :ok <- check_lists(persona),
         :ok <- check_first_chat_prompts(persona),
         :ok <- check_safe_write_seeds(persona),
         :ok <- check_seed_values(persona) do
      :ok
    end
  end

  @doc """
  The `settings_seeds` for a persona as an ordered list of `{key, value}` pairs
  (sorted by key) — the exact writes `apply_persona_profile` proposes.
  """
  @spec settings_seeds(persona()) :: [{String.t(), term()}]
  def settings_seeds(persona) when is_map(persona) do
    persona
    |> Map.get("settings_seeds", %{})
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  # -- validation helpers -----------------------------------------------------

  defp check_id(id, %{"persona_id" => id}), do: :ok
  defp check_id(id, %{"persona_id" => other}), do: {:error, {:id_mismatch, id, other}}
  defp check_id(_id, _persona), do: {:error, :missing_persona_id}

  defp check_label(%{"label" => label}) when is_binary(label) and label != "", do: :ok
  defp check_label(_persona), do: {:error, :missing_label}

  defp check_no_unknown_keys(persona) do
    case Map.keys(persona) -- @envelope_keys do
      [] -> :ok
      extra -> {:error, {:unknown_envelope_keys, extra}}
    end
  end

  defp check_lists(persona) do
    Enum.reduce_while(
      ~w(suggested_apps suggested_channels suggested_intents),
      :ok,
      fn key, :ok ->
        case Map.get(persona, key, []) do
          list when is_list(list) -> {:cont, :ok}
          _other -> {:halt, {:error, {:not_a_list, key}}}
        end
      end
    )
  end

  defp check_first_chat_prompts(persona) do
    case Map.get(persona, "first_chat_prompts", []) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: :ok, else: {:error, :non_string_prompt}

      _other ->
        {:error, :first_chat_prompts_not_a_list}
    end
  end

  defp check_safe_write_seeds(persona) do
    seeds = Map.get(persona, "settings_seeds", %{})

    if is_map(seeds) do
      case Enum.reject(Map.keys(seeds), &Settings.safe_write_key?/1) do
        [] -> :ok
        unsafe -> {:error, {:non_safe_write_keys, unsafe}}
      end
    else
      {:error, :settings_seeds_not_a_map}
    end
  end

  # v0.63 M7.1: validate seed VALUES against the schema at boot (bad enum, out-of-range
  # int, non-existent profile ref) so a value-invalid catalog fails fast here rather
  # than partially at apply time.
  defp check_seed_values(persona) do
    persona
    |> Map.get("settings_seeds", %{})
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
      case Settings.validate({key, value}) do
        {:ok, _} -> {:cont, :ok}
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_seed_value, key, reason}}}
      end
    end)
  end
end
