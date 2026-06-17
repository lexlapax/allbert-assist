defmodule AllbertAssist.Intent.Candidate do
  @moduledoc """
  Bounded intent candidate proposal data for the v0.19 intent engine.

  Candidates explain possible routes. They are not authority and do not
  execute. Selection still validates through registries, Security Central, and
  the action runner.
  """

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Runtime.SafeTerm

  @kinds ~w[action skill surface job channel memory objective refusal app_intent direct_answer]a
  @sources ~w[
    deterministic registry app plugin action generated overrides review learned_review
    job channel memory objective trace model
  ]a
  @statuses ~w[selected candidate rejected unavailable]a
  @max_string_bytes 240
  @default_total_limit 80
  @default_kind_limits %{
    action: 20,
    skill: 20,
    surface: 20,
    job: 10,
    channel: 10,
    memory: 10,
    objective: 5,
    app_intent: 20
  }

  defstruct [
    :kind,
    :id,
    :label,
    :source,
    :score,
    :selected?,
    :status,
    :reason,
    :rejection_reason,
    :action_name,
    :skill_name,
    :surface_id,
    :job_id,
    :channel_id,
    :app_id,
    :plugin_id,
    :permission,
    :execution_mode,
    :confirmation,
    resource_access: [],
    trace_metadata: %{}
  ]

  @type t :: %__MODULE__{
          kind: atom(),
          id: String.t(),
          label: String.t() | nil,
          source: atom(),
          score: float(),
          selected?: boolean(),
          status: atom(),
          reason: String.t() | nil,
          rejection_reason: atom() | String.t() | nil,
          action_name: String.t() | nil,
          skill_name: String.t() | nil,
          surface_id: String.t() | nil,
          job_id: String.t() | nil,
          channel_id: String.t() | nil,
          app_id: atom() | nil,
          plugin_id: String.t() | nil,
          permission: atom() | nil,
          execution_mode: atom() | nil,
          confirmation: atom() | nil,
          resource_access: [map()],
          trace_metadata: map()
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, kind} <- normalize_member(field(attrs, :kind), @kinds, :invalid_kind),
         {:ok, source} <-
           normalize_member(field(attrs, :source, :deterministic), @sources, :invalid_source),
         {:ok, status} <-
           normalize_member(field(attrs, :status, :candidate), @statuses, :invalid_status),
         {:ok, app_id} <- normalize_app_id(field(attrs, :app_id)),
         {:ok, action_name} <-
           normalize_action_name(kind, action_name_attr(kind, attrs), status) do
      candidate = %__MODULE__{
        kind: kind,
        id: bounded_string(field(attrs, :id) || action_name || fallback_id(kind, attrs)),
        label: optional_bounded_string(field(attrs, :label)),
        source: source,
        score: normalize_score(field(attrs, :score, 0.0)),
        selected?: field(attrs, :selected?, status == :selected) == true,
        status: status,
        reason: optional_bounded_string(field(attrs, :reason)),
        rejection_reason: field(attrs, :rejection_reason),
        action_name: action_name,
        skill_name: optional_bounded_string(field(attrs, :skill_name)),
        surface_id: optional_bounded_string(field(attrs, :surface_id)),
        job_id: optional_bounded_string(field(attrs, :job_id)),
        channel_id: optional_bounded_string(field(attrs, :channel_id)),
        app_id: app_id,
        plugin_id: optional_bounded_string(field(attrs, :plugin_id)),
        permission: field(attrs, :permission),
        execution_mode: field(attrs, :execution_mode),
        confirmation: field(attrs, :confirmation),
        resource_access: normalize_list(field(attrs, :resource_access)),
        trace_metadata: field(attrs, :trace_metadata, %{}) |> normalize_map() |> redact_map()
      }

      {:ok, candidate}
    end
  end

  def new(value), do: {:error, {:invalid_candidate, value}}

  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, candidate} -> candidate
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @spec selected_from_decision(map() | struct()) :: t()
  def selected_from_decision(decision) do
    selected_action = field(decision, :selected_action)
    selected_skill = field(decision, :selected_skill)

    kind =
      cond do
        is_binary(selected_action) -> :action
        is_binary(selected_skill) -> :skill
        true -> :direct_answer
      end

    new!(%{
      kind: kind,
      id:
        selected_action || selected_skill || to_string(field(decision, :intent, "direct_answer")),
      source: :deterministic,
      status: :selected,
      selected?: true,
      score: 1.0,
      action_name: selected_action,
      skill_name: selected_skill,
      app_id: field(decision, :active_app),
      permission: field(decision, :permission),
      execution_mode: field(decision, :execution_mode),
      confirmation: field(decision, :confirmation),
      resource_access: field(decision, :resource_access, []),
      reason: field(decision, :reason)
    })
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = candidate) do
    candidate
    |> Map.from_struct()
    |> Map.update!(:trace_metadata, &redact_map/1)
    |> drop_empty()
  end

  @spec to_maps([t() | map()]) :: [map()]
  def to_maps(candidates) when is_list(candidates) do
    Enum.map(candidates, fn
      %__MODULE__{} = candidate -> to_map(candidate)
      %{} = candidate -> candidate |> redact_map() |> drop_empty()
    end)
  end

  @spec bound([t() | map()], keyword()) :: [t() | map()]
  def bound(candidates, opts \\ []) when is_list(candidates) do
    total_limit = Keyword.get(opts, :total_limit, @default_total_limit)
    kind_limits = Keyword.get(opts, :kind_limits, @default_kind_limits)

    candidates
    |> Enum.reduce({[], %{}}, fn candidate, {acc, counts} ->
      kind = field(candidate, :kind)
      limit = Map.get(kind_limits, kind, total_limit)
      count = Map.get(counts, kind, 0)

      if count < limit and length(acc) < total_limit do
        {[redact(candidate) | acc], Map.put(counts, kind, count + 1)}
      else
        {acc, counts}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec redact(t() | map()) :: t() | map()
  def redact(%__MODULE__{} = candidate) do
    %{
      candidate
      | label: optional_bounded_string(candidate.label),
        reason: optional_bounded_string(candidate.reason),
        plugin_id: optional_bounded_string(candidate.plugin_id),
        trace_metadata: redact_map(candidate.trace_metadata)
    }
  end

  def redact(%{} = candidate) do
    candidate
    |> Enum.map(fn {key, value} -> {key, redact_value(value)} end)
    |> Map.new()
  end

  defp normalize_action_name(:action, action, :rejected),
    do: {:ok, optional_bounded_string(action)}

  defp normalize_action_name(_kind, nil, _status), do: {:ok, nil}

  defp normalize_action_name(:action, action, _status) do
    case ActionsRegistry.capability(action) do
      {:ok, capability} -> {:ok, capability.name}
      {:error, reason} -> {:error, {:unknown_action, action, reason}}
    end
  end

  defp normalize_action_name(_kind, action, _status), do: {:ok, optional_bounded_string(action)}

  defp action_name_attr(:action, attrs), do: field(attrs, :action_name) || field(attrs, :id)
  defp action_name_attr(_kind, attrs), do: field(attrs, :action_name)

  defp normalize_app_id(nil), do: {:ok, nil}

  defp normalize_app_id(app_id) do
    case AppRegistry.normalize_app_id(app_id) do
      {:ok, app_id} -> {:ok, app_id}
      {:error, _reason} -> {:error, {:unknown_app_id, app_id}}
    end
  catch
    :exit, _reason -> {:error, {:unknown_app_id, app_id}}
  end

  defp normalize_member(value, allowed, reason) when is_binary(value) do
    value
    |> String.trim()
    |> String.to_existing_atom()
    |> normalize_member(allowed, reason)
  rescue
    ArgumentError -> {:error, {reason, value}}
  end

  defp normalize_member(value, allowed, reason) do
    if value in allowed, do: {:ok, value}, else: {:error, {reason, value}}
  end

  defp normalize_score(value) when is_integer(value), do: normalize_score(value / 1)
  defp normalize_score(value) when is_float(value), do: value |> max(0.0) |> min(1.0)
  defp normalize_score(_value), do: 0.0

  defp fallback_id(kind, attrs), do: field(attrs, :"#{kind}_id") || kind

  defp optional_bounded_string(nil), do: nil
  defp optional_bounded_string(value), do: bounded_string(value)

  defp bounded_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.slice(0, @max_string_bytes)
  end

  defp normalize_list(nil), do: []
  defp normalize_list(value) when is_list(value), do: SafeTerm.to_list(value)
  defp normalize_list(value), do: [value]

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp redact_map(map) when is_map(map), do: Redactor.redact(map)

  defp redact_value(value) when is_binary(value), do: bounded_string(value)
  defp redact_value(value) when is_map(value), do: redact_map(value)
  defp redact_value(value) when is_list(value), do: SafeTerm.map_list(value, &redact_value/1)
  defp redact_value(value), do: value

  defp field(map, key, default \\ nil)

  defp field(%_struct{} = struct, key, default) do
    Map.get(struct, key, default)
  end

  defp field(map, key, default) when is_map(map) do
    string_key = Atom.to_string(key)
    Map.get(map, key, Map.get(map, string_key, default))
  end

  defp field(_value, _key, default), do: default

  defp drop_empty(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      {_key, value} when is_map(value) and map_size(value) == 0 -> true
      _entry -> false
    end)
  end
end
