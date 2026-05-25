defmodule AllbertAssist.DynamicPlugins.Codegen.CapabilityGap do
  @moduledoc """
  Normalized capability-gap request for v0.37 dynamic draft generation.

  This is producer-neutral request vocabulary, not authority. A gap may lead to
  source-bearing draft files and metadata, but it cannot enable live loading,
  trust a draft, run a sandbox gate, or integrate runtime actions.
  """

  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings

  @explicit_sources ~w[operator objective]
  @auto_sources ~w[intent intent_suggestion advisory agent]
  @default_target_shapes ["action"]

  @enforce_keys [:id, :slug, :summary, :source, :target_shapes]
  defstruct id: nil,
            objective_id: nil,
            step_id: nil,
            user_id: nil,
            slug: nil,
            summary: nil,
            requested_capability: nil,
            target_shapes: [],
            source: nil,
            confidence: nil,
            explicit?: false,
            producer: "codegen_llm",
            constraints: %{},
            context: %{},
            budget: %{}

  @type t :: %__MODULE__{
          id: String.t(),
          objective_id: String.t() | nil,
          step_id: String.t() | nil,
          user_id: String.t() | nil,
          slug: String.t(),
          summary: String.t(),
          requested_capability: String.t() | nil,
          target_shapes: [String.t()],
          source: String.t(),
          confidence: float() | nil,
          explicit?: boolean(),
          producer: String.t(),
          constraints: map(),
          context: map(),
          budget: map()
        }

  @doc "Normalize caller attrs and request context into a capability gap."
  @spec new(map(), map()) :: {:ok, t()} | {:error, term()}
  def new(attrs, context \\ %{}) when is_map(attrs) and is_map(context) do
    with {:ok, target_shapes} <- target_shapes(attrs),
         :ok <- validate_target_shapes(target_shapes),
         {:ok, slug} <- slug(attrs, request_summary(attrs) || "dynamic_draft") do
      {:ok, build_gap(attrs, context, slug, target_shapes)}
    end
  end

  @doc "Return :ok only for explicit operator/objective generation requests."
  @spec ensure_explicit(t()) :: :ok | {:error, term()}
  def ensure_explicit(%__MODULE__{source: source, explicit?: true})
      when source in @explicit_sources,
      do: :ok

  def ensure_explicit(%__MODULE__{source: source, confidence: confidence})
      when source in @auto_sources do
    {:error,
     {:dynamic_codegen_auto_generation_denied, %{"source" => source, "confidence" => confidence}}}
  end

  def ensure_explicit(%__MODULE__{source: source, explicit?: explicit?}) do
    {:error,
     {:dynamic_codegen_requires_explicit_request, %{"source" => source, "explicit" => explicit?}}}
  end

  @doc "Return a bounded map safe for metadata and objective events."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = gap) do
    %{
      "id" => gap.id,
      "objective_id" => gap.objective_id,
      "step_id" => gap.step_id,
      "user_id" => gap.user_id,
      "slug" => gap.slug,
      "summary" => bound(gap.summary),
      "requested_capability" => bound(gap.requested_capability),
      "target_shapes" => gap.target_shapes,
      "source" => gap.source,
      "confidence" => gap.confidence,
      "explicit" => gap.explicit?,
      "producer" => gap.producer,
      "constraints" => Redactor.redact(gap.constraints)
    }
  end

  defp target_shapes(attrs) do
    values =
      attrs
      |> field(:target_shapes)
      |> case do
        values when is_list(values) -> Enum.map(values, &to_string/1)
        value when is_binary(value) -> [value]
        _other -> @default_target_shapes
      end
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if values == [], do: {:error, :dynamic_codegen_target_required}, else: {:ok, values}
  end

  defp build_gap(attrs, context, slug, target_shapes) do
    summary = request_summary(attrs)
    source = source(attrs, context)

    %__MODULE__{
      id: text_field(attrs, :gap_id) || "gap_" <> Ecto.UUID.generate(),
      objective_id: text_field(attrs, :objective_id) || text_field(context, :objective_id),
      step_id: text_field(attrs, :step_id) || text_field(context, :step_id),
      user_id: text_field(attrs, :user_id) || text_field(context, :user_id),
      slug: slug,
      summary: summary || "Dynamic capability request",
      requested_capability: text_field(attrs, :requested_capability) || summary,
      target_shapes: target_shapes,
      source: source,
      confidence: confidence(attrs),
      explicit?: explicit?(attrs, context, source),
      constraints: map_field(attrs, :constraints),
      context: safe_context(context),
      budget: map_field(attrs, :budget)
    }
  end

  defp request_summary(attrs),
    do: text_field(attrs, :summary) || text_field(attrs, :requested_capability)

  defp source(attrs, context) do
    text_field(attrs, :source) || text_field(context, :source) || "operator"
  end

  defp validate_target_shapes(target_shapes) do
    allowed =
      case Settings.get("dynamic_codegen.allowed_targets") do
        {:ok, values} when is_list(values) -> values
        _other -> @default_target_shapes
      end

    case Enum.find(target_shapes, &(&1 not in allowed)) do
      nil -> :ok
      target -> {:error, {:dynamic_codegen_target_not_allowed, target}}
    end
  end

  defp slug(attrs, fallback) do
    value = text_field(attrs, :slug) || fallback

    slug =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 64)
      |> ensure_slug_start()

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, slug),
      do: {:ok, slug},
      else: {:error, {:invalid_slug, slug}}
  end

  defp ensure_slug_start(""), do: "dynamic_draft"

  defp ensure_slug_start(<<first::binary-size(1), _rest::binary>> = slug)
       when first in ~w[0 1 2 3 4 5 6 7 8 9], do: "d_" <> slug

  defp ensure_slug_start(slug), do: slug

  defp explicit?(attrs, context, source) do
    truthy?(field(attrs, :explicit_generation?)) or truthy?(field(attrs, :explicit?)) or
      truthy?(field(context, :explicit_generation?)) or source in @explicit_sources
  end

  defp confidence(attrs) do
    case field(attrs, :confidence) do
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1
      value when is_binary(value) -> parse_float(value)
      _other -> nil
    end
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp safe_context(context) do
    context
    |> Map.take([:actor, "actor", :channel, "channel", :surface, "surface", :source, "source"])
    |> Redactor.redact()
  end

  defp text_field(map, key) do
    case field(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) and not is_nil(value) ->
        Atom.to_string(value)

      _other ->
        nil
    end
  end

  defp map_field(map, key) do
    case field(map, key) do
      value when is_map(value) -> Redactor.redact(value)
      _other -> %{}
    end
  end

  defp field(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp truthy?(value), do: value in [true, "true", "yes", "1", 1]

  defp bound(nil), do: nil
  defp bound(value), do: value |> to_string() |> String.slice(0, 500)
end
