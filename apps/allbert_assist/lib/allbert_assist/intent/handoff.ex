defmodule AllbertAssist.Intent.Handoff do
  @moduledoc """
  Inert conversational app handoff or clarification proposal.

  A handoff explains what app action could handle a neutral prompt. It never
  sets active app context, authorizes permissions, or executes the action.
  """

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Runtime.Redactor

  @kinds [:app_handoff, :clarify_intent]
  @max_text_bytes 480
  @max_list_items 5

  @enforce_keys [:kind, :app_id, :action_name, :label]
  defstruct [
    :kind,
    :app_id,
    :action_name,
    :label,
    :candidate_id,
    :source_text,
    :reason,
    :surface_id,
    :destination,
    :confidence,
    :margin,
    :permission,
    :execution_mode,
    :confirmation,
    extracted_slots: %{},
    missing_slots: [],
    options: [],
    descriptor: %{},
    diagnostics: []
  ]

  @type t :: %__MODULE__{
          kind: :app_handoff | :clarify_intent,
          app_id: atom(),
          action_name: String.t(),
          label: String.t(),
          candidate_id: String.t() | nil,
          source_text: String.t() | nil,
          reason: String.t() | nil,
          surface_id: String.t(),
          destination: String.t() | nil,
          confidence: float() | nil,
          margin: float() | nil,
          permission: atom() | nil,
          execution_mode: atom() | nil,
          confirmation: atom() | nil,
          extracted_slots: map(),
          missing_slots: [atom()],
          options: [map()],
          descriptor: map(),
          diagnostics: [map()]
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, kind} <- kind(field(attrs, :kind)),
         {:ok, app_id} <- app_id(field(attrs, :app_id)),
         {:ok, action_name} <- required_string(field(attrs, :action_name), :action_name),
         {:ok, label} <- required_string(field(attrs, :label), :label) do
      handoff = %__MODULE__{
        kind: kind,
        app_id: app_id,
        action_name: action_name,
        label: label,
        candidate_id: optional_string(field(attrs, :candidate_id)),
        source_text: optional_string(field(attrs, :source_text)),
        reason: optional_string(field(attrs, :reason)),
        destination: optional_destination(field(attrs, :destination)),
        confidence: normalize_score(field(attrs, :confidence)),
        margin: normalize_score(field(attrs, :margin)),
        permission: field(attrs, :permission),
        execution_mode: field(attrs, :execution_mode),
        confirmation: field(attrs, :confirmation),
        extracted_slots: normalize_map(field(attrs, :extracted_slots, %{})),
        missing_slots: normalize_slots(field(attrs, :missing_slots, [])),
        options: normalize_options(field(attrs, :options, [])),
        descriptor: normalize_map(field(attrs, :descriptor, %{})),
        diagnostics: normalize_list(field(attrs, :diagnostics, []))
      }

      {:ok, %{handoff | surface_id: field(attrs, :surface_id) || surface_id(handoff)}}
    end
  end

  def new(value), do: {:error, {:invalid_handoff, value}}

  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, handoff} -> handoff
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @spec from_decision(map() | struct()) :: {:ok, t()} | {:error, term()}
  def from_decision(decision) do
    decision
    |> field(:trace_metadata, %{})
    |> field(:intent_handoff)
    |> case do
      %__MODULE__{} = handoff -> {:ok, handoff}
      %{} = attrs -> new(attrs)
      other -> {:error, {:missing_intent_handoff, other}}
    end
  end

  @spec to_map(t() | map() | nil) :: map() | nil
  def to_map(nil), do: nil

  def to_map(%__MODULE__{} = handoff) do
    handoff
    |> Map.from_struct()
    |> Map.update!(:extracted_slots, &string_key_map/1)
    |> Map.update!(:missing_slots, &Enum.map(&1, fn slot -> to_string(slot) end))
    |> Map.update!(:descriptor, &Redactor.redact/1)
    |> Map.update!(:options, &Redactor.redact/1)
    |> Redactor.redact()
    |> drop_empty()
  end

  def to_map(%{} = handoff), do: handoff |> Redactor.redact() |> drop_empty()

  @spec message(t()) :: String.t()
  def message(%__MODULE__{kind: :app_handoff} = handoff) do
    slot_summary = slot_summary(handoff.extracted_slots)

    if handoff.destination do
      "I can open #{destination_label(handoff.destination)} for #{handoff.label}#{slot_summary}. Accept the handoff to continue."
    else
      app = app_label(handoff.app_id)

      "I can hand this to #{app} for #{handoff.label}#{slot_summary}. Accept the handoff to continue."
    end
  end

  def message(%__MODULE__{kind: :clarify_intent, missing_slots: [slot | _rest]} = handoff) do
    "Which #{slot_label(slot)} should #{app_label(handoff.app_id)} use for #{handoff.label}?"
  end

  def message(%__MODULE__{kind: :clarify_intent}) do
    "I found more than one app route. Which option should handle this?"
  end

  def surface_id(%__MODULE__{} = handoff) do
    digest =
      :crypto.hash(:sha256, [
        Atom.to_string(handoff.kind),
        Atom.to_string(handoff.app_id),
        handoff.action_name || "",
        handoff.source_text || "",
        inspect(handoff.extracted_slots)
      ])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "intent_#{handoff.kind}_#{handoff.app_id}_#{handoff.action_name}_#{digest}"
  end

  defp kind(kind) when kind in @kinds, do: {:ok, kind}

  defp kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.to_existing_atom()
    |> kind()
  rescue
    ArgumentError -> {:error, {:invalid_kind, kind}}
  end

  defp kind(kind), do: {:error, {:invalid_kind, kind}}

  defp app_id(value) do
    case AppRegistry.normalize_app_id(value) do
      {:ok, app_id} when is_atom(app_id) -> {:ok, app_id}
      {:error, reason} -> {:error, {:invalid_app_id, reason}}
    end
  catch
    :exit, reason -> {:error, {:invalid_app_id, reason}}
  end

  defp required_string(value, field_name) do
    case optional_string(value) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_required, field_name}}
    end
  end

  defp optional_string(nil), do: nil

  defp optional_string(value) do
    value =
      value
      |> to_string()
      |> String.trim()

    cond do
      value == "" -> nil
      byte_size(value) <= @max_text_bytes -> value
      true -> binary_part(value, 0, @max_text_bytes)
    end
  end

  defp optional_destination(nil), do: nil

  defp optional_destination(value) do
    case optional_string(value) do
      "workspace:" <> tool -> "workspace:#{tool}"
      "app:" <> app_id -> "app:#{app_id}"
      _other -> nil
    end
  end

  defp normalize_score(nil), do: nil
  defp normalize_score(value) when is_integer(value), do: normalize_score(value / 1)
  defp normalize_score(value) when is_float(value), do: value |> max(0.0) |> min(1.0)
  defp normalize_score(_value), do: nil

  defp normalize_map(value) when is_map(value), do: value |> Redactor.redact() |> string_key_map()
  defp normalize_map(_value), do: %{}

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_value), do: []

  defp normalize_slots(values) when is_list(values) do
    values
    |> Enum.map(&slot_atom/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_slots(_values), do: []

  defp normalize_options(options) when is_list(options) do
    options
    |> Enum.map(&normalize_map/1)
    |> Enum.reject(&(&1 == %{}))
    |> Enum.take(@max_list_items)
  end

  defp normalize_options(_options), do: []

  defp slot_atom(value) when is_atom(value), do: value

  defp slot_atom(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.to_atom()
  end

  defp slot_atom(_value), do: nil

  defp string_key_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp drop_empty(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, "", [], %{}] end)
  end

  defp slot_summary(slots) when map_size(slots) == 0, do: ""

  defp slot_summary(slots) do
    values =
      slots
      |> Enum.map(fn {key, value} -> "#{slot_label(key)} #{value}" end)
      |> Enum.join(", ")

    " using #{values}"
  end

  defp slot_label(slot) do
    slot
    |> to_string()
    |> String.replace("_", " ")
  end

  defp app_label(:stocksage), do: "StockSage"

  defp app_label(app_id) when is_atom(app_id) do
    app_id
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp destination_label("workspace:calendar"), do: "Calendar"
  defp destination_label("workspace:mail"), do: "Mail"
  defp destination_label("workspace:github"), do: "GitHub"
  defp destination_label("workspace:discover"), do: "Discovery"

  defp destination_label("app:" <> app_id) do
    app_id
    |> String.replace("_", " ")
  end

  defp destination_label(destination), do: destination

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
