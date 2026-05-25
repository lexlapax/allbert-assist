defmodule AllbertAssist.DynamicPlugins.Draft do
  @moduledoc """
  File-backed v0.37 dynamic draft metadata.

  This is plain data. It grants no authority, and its `metadata.yaml` form is
  not a trust anchor for integration. The loader later re-checks source hashes,
  sandbox gate evidence, Settings Central policy, and Security Central
  confirmations before live registration.
  """

  @tiers ~w[
    draft
    sandbox_compiled
    sandbox_trialed
    gate_passed
    integrated
    rolled_back
    discarded
  ]

  @terminal_tiers ~w[discarded]

  @atom_keys %{
    "slug" => :slug,
    "revision" => :revision,
    "tier" => :tier,
    "producer" => :producer,
    "provider_profile" => :provider_profile,
    "target_shapes" => :target_shapes,
    "source_hashes" => :source_hashes,
    "compiled_paths" => :compiled_paths,
    "scan_paths" => :scan_paths,
    "budget" => :budget,
    "gate" => :gate,
    "static_validation" => :static_validation,
    "confirmations" => :confirmations,
    "diagnostics" => :diagnostics,
    "repair_history" => :repair_history,
    "timestamps" => :timestamps,
    "root" => :root,
    "updated_at" => :updated_at
  }

  @enforce_keys [:slug, :revision]
  defstruct schema_version: 1,
            slug: nil,
            revision: nil,
            tier: "draft",
            producer: "manual",
            provider_profile: nil,
            target_shapes: [],
            source_hashes: %{},
            compiled_paths: [],
            scan_paths: [],
            budget: %{"provider_calls_used" => 0, "provider_usage_units_used" => 0},
            gate: %{"status" => "not_run", "sandbox_report_id" => nil},
            static_validation: %{"status" => "not_run"},
            confirmations: %{"integration_id" => nil, "rollback_id" => nil},
            diagnostics: [],
            repair_history: [],
            timestamps: %{},
            root: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          slug: String.t(),
          revision: String.t(),
          tier: String.t(),
          producer: String.t(),
          provider_profile: String.t() | nil,
          target_shapes: [String.t()],
          source_hashes: %{String.t() => String.t()},
          compiled_paths: [String.t()],
          scan_paths: [String.t()],
          budget: map(),
          gate: map(),
          static_validation: map(),
          confirmations: map(),
          diagnostics: [map()],
          repair_history: [map()],
          timestamps: map(),
          root: String.t() | nil
        }

  @doc "Return legal v0.37 draft tiers."
  @spec tiers() :: [String.t()]
  def tiers, do: @tiers

  @doc "Normalize metadata into a draft struct."
  @spec new(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs, opts \\ []) when is_map(attrs) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)

    draft = %__MODULE__{
      slug: value(attrs, "slug"),
      revision: value(attrs, "revision") || revision_id(now),
      tier: value(attrs, "tier", "draft"),
      producer: value(attrs, "producer", "manual"),
      provider_profile: value(attrs, "provider_profile"),
      target_shapes: list_value(attrs, "target_shapes"),
      source_hashes: map_value(attrs, "source_hashes"),
      compiled_paths: list_value(attrs, "compiled_paths"),
      scan_paths: list_value(attrs, "scan_paths"),
      budget:
        map_value(attrs, "budget", %{
          "provider_calls_used" => 0,
          "provider_usage_units_used" => 0
        }),
      gate: map_value(attrs, "gate", %{"status" => "not_run", "sandbox_report_id" => nil}),
      static_validation: map_value(attrs, "static_validation", %{"status" => "not_run"}),
      confirmations:
        map_value(attrs, "confirmations", %{"integration_id" => nil, "rollback_id" => nil}),
      diagnostics: data_list_value(attrs, "diagnostics"),
      repair_history: data_list_value(attrs, "repair_history"),
      timestamps: timestamps(attrs, now),
      root: value(attrs, "root")
    }

    with :ok <- validate_slug(draft.slug),
         :ok <- validate_revision(draft.revision),
         :ok <- validate_tier(draft.tier),
         :ok <- validate_string_list(draft.target_shapes, :target_shapes),
         :ok <- validate_string_list(draft.compiled_paths, :compiled_paths),
         :ok <- validate_string_list(draft.scan_paths, :scan_paths) do
      {:ok, draft}
    end
  end

  @doc "Convert draft metadata to YAML-safe string-keyed data."
  @spec to_metadata_map(t()) :: map()
  def to_metadata_map(%__MODULE__{} = draft) do
    %{
      "schema_version" => draft.schema_version,
      "slug" => draft.slug,
      "revision" => draft.revision,
      "tier" => draft.tier,
      "producer" => draft.producer,
      "provider_profile" => draft.provider_profile,
      "target_shapes" => draft.target_shapes,
      "source_hashes" => draft.source_hashes,
      "compiled_paths" => draft.compiled_paths,
      "scan_paths" => draft.scan_paths,
      "budget" => draft.budget,
      "gate" => draft.gate,
      "static_validation" => draft.static_validation,
      "confirmations" => draft.confirmations,
      "diagnostics" => draft.diagnostics,
      "repair_history" => draft.repair_history,
      "timestamps" => draft.timestamps
    }
  end

  @doc "Return operator-facing draft summary data."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = draft) do
    %{
      slug: draft.slug,
      revision: draft.revision,
      tier: draft.tier,
      producer: draft.producer,
      target_shapes: draft.target_shapes,
      gate_status: Map.get(draft.gate, "status"),
      static_validation_status: Map.get(draft.static_validation, "status"),
      integration_confirmation_id: Map.get(draft.confirmations, "integration_id"),
      rollback_confirmation_id: Map.get(draft.confirmations, "rollback_id"),
      diagnostics: draft.diagnostics,
      created_at: Map.get(draft.timestamps, "created_at"),
      updated_at: Map.get(draft.timestamps, "updated_at"),
      root: draft.root
    }
  end

  @doc "Return true when a draft cannot transition out of its tier."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{tier: tier}), do: tier in @terminal_tiers

  @doc "Return an updated draft tier, preserving evidence fields."
  @spec put_tier(t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def put_tier(%__MODULE__{} = draft, tier, opts \\ []) do
    with :ok <- validate_tier(tier),
         :ok <- ensure_transition_allowed(draft, tier) do
      now =
        opts
        |> Keyword.get(:now, DateTime.utc_now())
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      {:ok, %{draft | tier: tier, timestamps: Map.put(draft.timestamps, "updated_at", now)}}
    end
  end

  defp ensure_transition_allowed(%__MODULE__{tier: "discarded"}, "discarded"), do: :ok

  defp ensure_transition_allowed(%__MODULE__{tier: "discarded"}, _tier),
    do: {:error, :discarded_terminal}

  defp ensure_transition_allowed(%__MODULE__{tier: "integrated"}, "discarded"),
    do: {:error, :rollback_required}

  defp ensure_transition_allowed(_draft, _tier), do: :ok

  defp timestamps(attrs, now) do
    existing = map_value(attrs, "timestamps")
    now = DateTime.to_iso8601(now)

    existing
    |> Map.put_new("created_at", now)
    |> Map.put("updated_at", value(existing, "updated_at") || now)
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    atom_key = Map.fetch!(@atom_keys, key)
    Map.get(map, key, Map.get(map, atom_key, default))
  end

  defp list_value(map, key) do
    case value(map, key, []) do
      values when is_list(values) -> Enum.map(values, &to_string/1)
      _other -> []
    end
  end

  defp data_list_value(map, key) do
    case value(map, key, []) do
      values when is_list(values) -> Enum.map(values, &stringify_nested/1)
      _other -> []
    end
  end

  defp map_value(map, key, default \\ %{}) do
    case value(map, key, default) do
      value when is_map(value) -> stringify_keys(value)
      _other -> default
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_nested(value)}
    end)
  end

  defp stringify_nested(value) when is_map(value), do: stringify_keys(value)
  defp stringify_nested(values) when is_list(values), do: Enum.map(values, &stringify_nested/1)
  defp stringify_nested(value), do: value

  defp validate_slug(slug) when is_binary(slug) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, slug), do: :ok, else: {:error, {:invalid_slug, slug}}
  end

  defp validate_slug(slug), do: {:error, {:invalid_slug, slug}}

  defp validate_revision(revision) when is_binary(revision) do
    if Regex.match?(~r/^[A-Za-z0-9_.-]+$/, revision),
      do: :ok,
      else: {:error, {:invalid_revision, revision}}
  end

  defp validate_revision(revision), do: {:error, {:invalid_revision, revision}}

  defp validate_tier(tier) when tier in @tiers, do: :ok
  defp validate_tier(tier), do: {:error, {:invalid_tier, tier}}

  defp validate_string_list(values, field) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, {:invalid_string_list, field}}
    end
  end

  defp revision_id(now) do
    "rev_" <> Calendar.strftime(now, "%Y_%m_%d_%H%M%S")
  end
end
