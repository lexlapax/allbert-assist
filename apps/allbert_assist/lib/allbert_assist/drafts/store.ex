defmodule AllbertAssist.Drafts.Store do
  @moduledoc """
  Unified facade for inert review drafts.

  v0.47 keeps v0.37 dynamic plugin draft metadata in its compatibility root and
  delegates those records through this facade as `kind: "code"`. Non-code
  drafts are file-backed data under `drafts/` and have no live authority.
  """

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.Codegen.CapabilityGap
  alias AllbertAssist.DynamicPlugins.Draft, as: DynamicPluginDraft
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.YamlCodec
  alias AllbertAssist.Workflows.Validator

  @metadata_suffix ".metadata.yaml"
  @handoff_kinds ~w[capability_gap objective]
  @non_code_kinds ~w[skill workflow memory_promotion memory_update] ++ @handoff_kinds
  @non_code_tiers ~w[draft discarded promoted]
  @slug_pattern ~r/^[a-z][a-z0-9_]*$/

  @type draft_kind :: String.t()
  @type non_code_draft_summary :: %{
          required(:artifact_path) => term(),
          required(:created_at) => term(),
          required(:diagnostics) => list(),
          required(:id) => term(),
          required(:kind) => term(),
          required(:live_authority) => term(),
          required(:payload) => map(),
          required(:promotion) => term(),
          required(:provenance) => term(),
          required(:root) => String.t(),
          required(:slug) => term(),
          required(:source_suggestion_id) => term(),
          required(:tier) => term(),
          required(:updated_at) => term()
        }
  @type dynamic_draft_summary :: %{
          required(:id) => term(),
          required(:kind) => term(),
          required(:live_authority) => term(),
          required(:source) => String.t(),
          optional(atom()) => term()
        }
  @type draft_summary :: non_code_draft_summary() | dynamic_draft_summary()

  @doc "Create or rewrite an inert skill draft."
  @spec create_skill_draft(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_skill_draft(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- normalize_create_attrs("skill", attrs),
         :ok <- ensure_open_draft_capacity(attrs["id"]),
         payload <- skill_payload(attrs),
         :ok <- write_artifact(attrs, payload),
         {:ok, draft} <- put_non_code_draft(attrs, payload, opts) do
      {:ok, draft}
    end
  end

  @doc "Create or rewrite an inert workflow draft after v0.44 schema validation."
  @spec create_workflow_draft(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_workflow_draft(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, attrs} <- normalize_create_attrs("workflow", attrs),
         :ok <- ensure_open_draft_capacity(attrs["id"]),
         workflow <- Map.get(attrs, "workflow") || workflow_payload(attrs),
         {:ok, workflow} <- Validator.validate(workflow),
         payload <- Map.put(workflow_draft_payload(attrs), "workflow", workflow),
         :ok <- write_artifact(attrs, workflow),
         {:ok, draft} <- put_non_code_draft(attrs, payload, opts) do
      {:ok, draft}
    end
  end

  @doc "Create or rewrite an inert memory promotion/update draft."
  @spec create_memory_draft(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_memory_draft(attrs, opts \\ []) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    kind = Map.get(attrs, "kind", "memory_promotion")

    with {:ok, attrs} <- normalize_create_attrs(kind, attrs),
         :ok <- ensure_open_draft_capacity(attrs["id"]),
         payload <- memory_draft_payload(attrs),
         :ok <- write_artifact(attrs, payload),
         {:ok, draft} <- put_non_code_draft(attrs, payload, opts) do
      {:ok, draft}
    end
  end

  @doc "Create or rewrite an inert capability-gap handoff draft."
  @spec create_capability_gap_draft(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_capability_gap_draft(attrs, opts \\ []) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, attrs} <- normalize_create_attrs("capability_gap", attrs),
         :ok <- ensure_open_draft_capacity(attrs["id"]),
         {:ok, payload} <- capability_gap_payload(attrs),
         :ok <- write_artifact(attrs, payload),
         {:ok, draft} <- put_non_code_draft(attrs, payload, opts) do
      {:ok, draft}
    end
  end

  @doc "Create or rewrite an inert declarative objective draft."
  @spec create_objective_draft(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_objective_draft(attrs, opts \\ []) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, attrs} <- normalize_create_attrs("objective", attrs),
         :ok <- ensure_open_draft_capacity(attrs["id"]),
         payload <- objective_draft_payload(attrs),
         :ok <- write_artifact(attrs, payload),
         {:ok, draft} <- put_non_code_draft(attrs, payload, opts) do
      {:ok, draft}
    end
  end

  @doc "List dynamic-code and non-code draft summaries."
  @spec list_drafts(keyword()) :: [draft_summary()]
  def list_drafts(opts \\ []) when is_list(opts) do
    kind = opts |> Keyword.get(:kind) |> normalize_kind_filter()

    (dynamic_draft_summaries() ++ non_code_draft_summaries())
    |> Enum.filter(&matches_kind?(&1, kind))
    |> Enum.sort_by(&{Map.get(&1, :kind), Map.get(&1, :id)})
  end

  @doc "Show one draft by unified id or dynamic plugin slug."
  @spec show_draft(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def show_draft(id, opts \\ []) when is_binary(id) and is_list(opts) do
    kind = opts |> Keyword.get(:kind) |> normalize_kind_filter()

    case kind do
      "code" -> show_dynamic_draft(id)
      kind when kind in @non_code_kinds -> read_non_code_draft(kind, id)
      nil -> show_any_draft(id)
      other -> {:error, {:invalid_draft_kind, other}}
    end
  end

  @doc "Discard one inert draft. Dynamic code drafts continue through v0.37."
  @spec discard_draft(String.t(), keyword()) :: {:ok, draft_summary()} | {:error, term()}
  def discard_draft(id, opts \\ []) when is_binary(id) and is_list(opts) do
    kind = opts |> Keyword.get(:kind) |> normalize_kind_filter()

    case kind do
      "code" -> discard_dynamic_draft(id, opts)
      kind when kind in @non_code_kinds -> discard_non_code_draft(kind, id, opts)
      nil -> discard_any_draft(id, opts)
      other -> {:error, {:invalid_draft_kind, other}}
    end
  end

  @doc "Mark one non-code draft promoted after its live write completed."
  @spec promote_draft(String.t(), keyword()) :: {:ok, non_code_draft_summary()} | {:error, term()}
  def promote_draft(id, opts \\ []) when is_binary(id) and is_list(opts) do
    kind = opts |> Keyword.get(:kind) |> normalize_kind_filter()
    promotion = opts |> Keyword.get(:promotion, %{}) |> stringify_keys()
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)

    case kind do
      kind when kind in @non_code_kinds ->
        promote_non_code_draft(kind, id, promotion, now)

      nil ->
        promote_any_non_code_draft(id, promotion, now)

      other ->
        {:error, {:invalid_draft_kind, other}}
    end
  end

  @doc "Return true when a non-code draft id is valid for filesystem storage."
  @spec valid_id?(String.t()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Regex.match?(@slug_pattern, id)
  def valid_id?(_id), do: false

  defp normalize_create_attrs(kind, attrs) do
    attrs = stringify_keys(attrs)
    summary = attrs |> Map.get("summary", "") |> to_string() |> String.trim()
    source_id = attrs |> Map.get("source_suggestion_id", "") |> to_string() |> String.trim()

    id =
      attrs
      |> Map.get("id")
      |> normalize_id()
      |> case do
        nil -> generated_id(kind, source_id, summary)
        id -> id
      end

    cond do
      kind not in @non_code_kinds ->
        {:error, {:invalid_draft_kind, kind}}

      not valid_id?(id) ->
        {:error, {:invalid_draft_id, id}}

      summary == "" ->
        {:error, :summary_required}

      true ->
        {:ok,
         attrs
         |> Map.put("id", id)
         |> Map.put("kind", kind)
         |> Map.put("summary", summary)
         |> Map.put("source_suggestion_id", empty_to_nil(source_id))
         |> Map.put_new("evidence_refs", [])}
    end
  end

  defp put_non_code_draft(attrs, payload, opts) do
    kind = Map.fetch!(attrs, "kind")
    id = Map.fetch!(attrs, "id")
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)
    existing = existing_timestamps(kind, id)
    artifact_path = artifact_path(kind, id)

    draft =
      %{
        "schema_version" => 1,
        "id" => id,
        "kind" => kind,
        "tier" => Map.get(attrs, "tier", "draft"),
        "payload" => payload,
        "provenance" => provenance(attrs),
        "diagnostics" => diagnostics(attrs),
        "artifact_path" => artifact_path,
        "live_authority" => false,
        "timestamps" =>
          existing
          |> Map.put_new("created_at", DateTime.to_iso8601(now))
          |> Map.put("updated_at", DateTime.to_iso8601(now))
      }

    with :ok <- validate_tier(draft["tier"]),
         :ok <- write_yaml(metadata_path(kind, id), draft) do
      {:ok, summary(draft)}
    end
  end

  defp read_non_code_draft(kind, id) do
    with {:ok, id} <- normalize_existing_id(id),
         :ok <- ensure_non_code_kind(kind),
         {:ok, metadata} <- read_existing_metadata(kind, id) do
      {:ok, summary(metadata)}
    end
  end

  defp discard_non_code_draft(kind, id, opts) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)

    with {:ok, id} <- normalize_existing_id(id),
         :ok <- ensure_non_code_kind(kind),
         {:ok, metadata} <- read_existing_metadata(kind, id),
         :ok <- ensure_non_terminal(metadata),
         updated <-
           metadata
           |> Map.put("tier", "discarded")
           |> put_in(["timestamps", "updated_at"], DateTime.to_iso8601(now)),
         :ok <- write_yaml(metadata_path(kind, id), updated) do
      {:ok, summary(updated)}
    end
  end

  defp promote_non_code_draft(kind, id, promotion, now) do
    with {:ok, id} <- normalize_existing_id(id),
         :ok <- ensure_non_code_kind(kind),
         {:ok, metadata} <- read_existing_metadata(kind, id),
         :ok <- ensure_non_terminal(metadata),
         updated <-
           metadata
           |> Map.put("tier", "promoted")
           |> Map.put("promotion", promotion)
           |> put_in(["timestamps", "updated_at"], DateTime.to_iso8601(now)),
         :ok <- write_yaml(metadata_path(kind, id), updated) do
      {:ok, summary(updated)}
    end
  end

  defp promote_any_non_code_draft(id, promotion, now) do
    case show_any_non_code_draft(id) do
      {:ok, %{kind: kind}} -> promote_non_code_draft(kind, id, promotion, now)
      {:error, reason} -> {:error, reason}
    end
  end

  defp discard_any_draft(id, opts) do
    case show_any_non_code_draft(id) do
      {:ok, %{kind: kind}} -> discard_non_code_draft(kind, id, opts)
      {:error, :not_found} -> discard_dynamic_draft(id, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp show_any_draft(id) do
    case show_any_non_code_draft(id) do
      {:ok, draft} -> {:ok, draft}
      {:error, :not_found} -> show_dynamic_draft(id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp show_any_non_code_draft(id) do
    Enum.find_value(@non_code_kinds, {:error, :not_found}, fn kind ->
      case read_non_code_draft(kind, id) do
        {:ok, draft} -> {:ok, draft}
        {:error, :not_found} -> nil
        {:error, _reason} -> nil
      end
    end)
  end

  defp show_dynamic_draft("code:" <> slug), do: show_dynamic_draft(slug)

  defp show_dynamic_draft(slug) do
    case DynamicPlugins.show_draft(slug) do
      {:ok, summary} -> {:ok, dynamic_summary(summary)}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp discard_dynamic_draft("code:" <> slug, opts), do: discard_dynamic_draft(slug, opts)

  defp discard_dynamic_draft(slug, opts) do
    case DynamicPlugins.discard_draft(slug, opts) do
      {:ok, draft} -> {:ok, dynamic_summary(DynamicPluginDraft.summary(draft))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dynamic_draft_summaries do
    DynamicPlugins.list_drafts()
    |> Enum.map(&dynamic_summary/1)
  end

  defp dynamic_summary(summary) when is_map(summary) do
    summary
    |> Map.put(:id, Map.get(summary, :slug))
    |> Map.put(:kind, "code")
    |> Map.put(:source, "dynamic_plugins")
    |> Map.put(:live_authority, false)
  end

  defp non_code_draft_summaries do
    @non_code_kinds
    |> Enum.flat_map(fn kind ->
      kind
      |> kind_root()
      |> metadata_files()
      |> Enum.flat_map(&metadata_summary/1)
    end)
  end

  defp metadata_summary(path) do
    case read_yaml(path) do
      {:ok, metadata} -> [summary(metadata)]
      {:error, _reason} -> []
    end
  end

  defp summary(metadata) do
    payload = Map.get(metadata, "payload", %{})

    %{
      id: Map.get(metadata, "id"),
      slug: Map.get(metadata, "id"),
      kind: Map.get(metadata, "kind"),
      tier: Map.get(metadata, "tier"),
      payload: payload,
      provenance: Map.get(metadata, "provenance", %{}),
      diagnostics: Map.get(metadata, "diagnostics", []),
      artifact_path: Map.get(metadata, "artifact_path"),
      live_authority: Map.get(metadata, "live_authority", false),
      promotion: Map.get(metadata, "promotion", %{}),
      source_suggestion_id: Map.get(payload, "source_suggestion_id"),
      created_at: get_in(metadata, ["timestamps", "created_at"]),
      updated_at: get_in(metadata, ["timestamps", "updated_at"]),
      root: kind_root(Map.get(metadata, "kind"))
    }
  end

  defp skill_payload(attrs) do
    %{
      "schema_version" => 1,
      "kind" => "skill",
      "id" => Map.fetch!(attrs, "id"),
      "name" => Map.get(attrs, "title") || title_from_summary(Map.fetch!(attrs, "summary")),
      "description" => Map.fetch!(attrs, "summary"),
      "instructions" => Map.get(attrs, "instructions", Map.fetch!(attrs, "summary")),
      "enabled" => false,
      "trust_status" => "untrusted",
      "live_authority" => false,
      "source_suggestion_id" => Map.get(attrs, "source_suggestion_id"),
      "evidence_refs" => list_value(Map.get(attrs, "evidence_refs"))
    }
  end

  defp workflow_draft_payload(attrs) do
    %{
      "schema_version" => 1,
      "kind" => "workflow",
      "id" => Map.fetch!(attrs, "id"),
      "enabled" => false,
      "live_authority" => false,
      "source_suggestion_id" => Map.get(attrs, "source_suggestion_id"),
      "evidence_refs" => list_value(Map.get(attrs, "evidence_refs")),
      "static_validation" => %{"status" => "passed", "schema_version" => 1}
    }
  end

  defp memory_draft_payload(attrs) do
    summary = Map.fetch!(attrs, "summary")
    body = attrs |> Map.get("body", summary) |> to_string() |> String.trim()
    category = attrs |> Map.get("category", "notes") |> to_string()

    %{
      "schema_version" => 1,
      "kind" => Map.fetch!(attrs, "kind"),
      "id" => Map.fetch!(attrs, "id"),
      "enabled" => false,
      "live_authority" => false,
      "source_suggestion_id" => Map.get(attrs, "source_suggestion_id"),
      "evidence_refs" => list_value(Map.get(attrs, "evidence_refs")),
      "memory" =>
        %{
          "category" => category,
          "summary" => summary,
          "body" => if(body == "", do: summary, else: body)
        }
        |> put_optional("path", Map.get(attrs, "path"))
    }
  end

  defp capability_gap_payload(attrs) do
    with {:ok, gap} <- CapabilityGap.new(attrs, %{"source" => "self_improvement"}) do
      {:ok,
       %{
         "schema_version" => 1,
         "kind" => "capability_gap",
         "id" => Map.fetch!(attrs, "id"),
         "enabled" => false,
         "live_authority" => false,
         "source_suggestion_id" => Map.get(attrs, "source_suggestion_id"),
         "evidence_refs" => list_value(Map.get(attrs, "evidence_refs")),
         "capability_gap" => CapabilityGap.summary(gap),
         "handoff" => %{
           "dynamic_draft_requested" => false,
           "dynamic_draft_id" => nil,
           "sandbox_gate_status" => "not_started",
           "gate_required_before_integration" => true
         }
       }}
    end
  end

  defp objective_draft_payload(attrs) do
    summary = Map.fetch!(attrs, "summary")

    %{
      "schema_version" => 1,
      "kind" => "objective",
      "id" => Map.fetch!(attrs, "id"),
      "enabled" => false,
      "live_authority" => false,
      "source_suggestion_id" => Map.get(attrs, "source_suggestion_id"),
      "evidence_refs" => list_value(Map.get(attrs, "evidence_refs")),
      "objective" =>
        %{
          "title" => Map.get(attrs, "title", summary),
          "objective" => Map.get(attrs, "objective", Map.get(attrs, "body", summary)),
          "acceptance_criteria" => map_value(Map.get(attrs, "acceptance_criteria")),
          "constraints" => map_value(Map.get(attrs, "constraints")),
          "user_id" => Map.get(attrs, "user_id"),
          "active_app" => Map.get(attrs, "active_app"),
          "source_thread_id" => Map.get(attrs, "source_thread_id"),
          "session_id" => Map.get(attrs, "session_id")
        }
        |> drop_nil_values(),
      "handoff" => %{
        "objective_framed" => false,
        "objective_id" => nil,
        "confirmation_required" => true
      }
    }
  end

  defp workflow_payload(attrs) do
    id = Map.fetch!(attrs, "id")
    summary = Map.fetch!(attrs, "summary")

    %{
      "id" => id,
      "version" => 1,
      "description" => summary,
      "owner" => "self_improvement",
      "inputs" => [],
      "steps" => [
        %{
          "id" => "review",
          "kind" => "reflect",
          "prompt" => summary,
          "save_as" => "review"
        }
      ]
    }
  end

  defp write_artifact(%{"kind" => "skill", "id" => id}, payload) do
    write_yaml(artifact_path("skill", id), payload)
  end

  defp write_artifact(%{"kind" => "workflow", "id" => id}, workflow) do
    write_yaml(artifact_path("workflow", id), workflow)
  end

  defp write_artifact(%{"kind" => kind, "id" => id}, payload)
       when kind in ["memory_promotion", "memory_update"] do
    write_yaml(artifact_path(kind, id), payload)
  end

  defp write_artifact(%{"kind" => kind, "id" => id}, payload) when kind in @handoff_kinds do
    write_yaml(artifact_path(kind, id), payload)
  end

  defp ensure_open_draft_capacity(id) do
    if existing_non_code_draft?(id) do
      :ok
    else
      cap = settings_value("self_improvement.drafts.max_open", 50)
      open_count = Enum.count(non_code_draft_summaries(), &(&1.tier == "draft"))

      if open_count < cap, do: :ok, else: {:error, {:max_open_drafts, cap}}
    end
  end

  defp existing_non_code_draft?(id) do
    Enum.any?(@non_code_kinds, fn kind ->
      File.regular?(metadata_path(kind, id))
    end)
  end

  defp existing_timestamps(kind, id) do
    case read_existing_metadata(kind, id) do
      {:ok, metadata} -> Map.get(metadata, "timestamps", %{})
      {:error, _reason} -> %{}
    end
  end

  defp read_existing_metadata(kind, id) do
    path = metadata_path(kind, id)

    if File.regular?(path) do
      read_yaml(path)
    else
      {:error, :not_found}
    end
  end

  defp metadata_files(root) do
    root
    |> Path.join("*#{@metadata_suffix}")
    |> Path.wildcard()
  end

  defp metadata_path(kind, id), do: Path.join(kind_root(kind), id <> @metadata_suffix)

  defp artifact_path("skill", id), do: Path.join(Paths.drafts_skills_root(), id <> ".skill.yaml")
  defp artifact_path("workflow", id), do: Path.join(Paths.drafts_workflows_root(), id <> ".yaml")

  defp artifact_path(kind, id) when kind in ["memory_promotion", "memory_update"],
    do: Path.join(Paths.drafts_memory_root(), id <> ".memory.yaml")

  defp artifact_path("capability_gap", id),
    do: Path.join(kind_root("capability_gap"), id <> ".capability_gap.yaml")

  defp artifact_path("objective", id),
    do: Path.join(kind_root("objective"), id <> ".objective.yaml")

  defp kind_root("skill"), do: Paths.drafts_skills_root()
  defp kind_root("workflow"), do: Paths.drafts_workflows_root()

  defp kind_root(kind) when kind in ["memory_promotion", "memory_update"],
    do: Paths.drafts_memory_root()

  defp kind_root("capability_gap"), do: Path.join(Paths.drafts_root(), "capability_gaps")
  defp kind_root("objective"), do: Path.join(Paths.drafts_root(), "objectives")

  defp kind_root(_kind), do: Paths.drafts_root()

  defp write_yaml(path, map) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, YamlCodec.encode!(map))
    end
  end

  defp read_yaml(path) do
    case YamlCodec.read_file(path) do
      {:ok, map} when map == %{} -> {:error, :not_found}
      other -> other
    end
  end

  defp ensure_non_code_kind(kind) when kind in @non_code_kinds, do: :ok
  defp ensure_non_code_kind(kind), do: {:error, {:invalid_draft_kind, kind}}

  defp ensure_non_terminal(%{"tier" => "discarded"}), do: {:error, :discarded_terminal}
  defp ensure_non_terminal(%{"tier" => "promoted"}), do: {:error, :promoted_terminal}
  defp ensure_non_terminal(_metadata), do: :ok

  defp validate_tier(tier) when tier in @non_code_tiers, do: :ok
  defp validate_tier(tier), do: {:error, {:invalid_draft_tier, tier}}

  defp normalize_existing_id(id) do
    case normalize_id(id) do
      nil -> {:error, {:invalid_draft_id, id}}
      id -> {:ok, id}
    end
  end

  defp normalize_id(nil), do: nil

  defp normalize_id("code:" <> id), do: normalize_id(id)

  defp normalize_id(id) when is_binary(id) do
    id = id |> String.trim() |> String.replace("-", "_")
    if valid_id?(id), do: id, else: nil
  end

  defp normalize_id(_id), do: nil

  defp normalize_kind_filter(nil), do: nil

  defp normalize_kind_filter(kind) when kind in [:skill, :workflow, :code],
    do: Atom.to_string(kind)

  defp normalize_kind_filter(kind) when is_binary(kind), do: kind
  defp normalize_kind_filter(kind), do: to_string(kind)

  defp matches_kind?(_draft, nil), do: true
  defp matches_kind?(draft, kind), do: Map.get(draft, :kind) == kind

  defp generated_id(kind, source_id, summary) do
    hash =
      "#{kind}:#{source_id}:#{summary}"
      |> sha256()
      |> binary_part(0, 10)

    "#{kind}_#{hash}"
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp title_from_summary(summary) do
    summary
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(8)
    |> Enum.join(" ")
  end

  defp provenance(attrs) do
    attrs
    |> Map.get("provenance", %{"source" => "self_improvement"})
    |> stringify_keys()
  end

  defp diagnostics(attrs) do
    attrs
    |> Map.get("diagnostics", [])
    |> list_value()
  end

  defp list_value(values) when is_list(values), do: Enum.map(values, &stringify_nested/1)
  defp list_value(_value), do: []

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_nested(value)} end)
  end

  defp stringify_nested(value) when is_map(value), do: stringify_keys(value)
  defp stringify_nested(values) when is_list(values), do: Enum.map(values, &stringify_nested/1)
  defp stringify_nested(value), do: value

  defp map_value(value) when is_map(value), do: stringify_keys(value)
  defp map_value(_value), do: %{}

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp settings_value(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  rescue
    _exception -> default
  end
end
