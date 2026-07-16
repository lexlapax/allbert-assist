defmodule AllbertAssist.Intent.ApprovalHandoff do
  @moduledoc """
  Plain-data Approval Handoff contract for channel-native approval surfaces.

  The handoff is display and routing metadata only. Approval, denial, grant
  matching, and target resumption still happen through the registered
  confirmation and action-runner boundaries.
  """

  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Intent.ResourceAccess
  alias AllbertAssist.Maps

  @statuses ~w[pending approved denied expired resolved]a

  defstruct [
    :confirmation_id,
    :status,
    :target_action,
    :risk_summary,
    :origin,
    :result_return,
    resource_access: [],
    allowed_actions: [],
    render_hints: %{},
    diagnostics: []
  ]

  @type t :: %__MODULE__{
          confirmation_id: String.t() | nil,
          status: atom(),
          target_action: map() | nil,
          resource_access: [ResourceAccess.t() | map()],
          risk_summary: String.t() | nil,
          origin: map() | nil,
          allowed_actions: [atom() | map()],
          render_hints: map(),
          result_return: map() | nil,
          diagnostics: [map()]
        }

  @spec pending(Decision.t() | map(), map(), map()) :: t()
  def pending(decision, action_result, context \\ %{}) do
    confirmation = field(action_result, :confirmation, %{}) || %{}
    confirmation_id = field(action_result, :confirmation_id) || field(confirmation, :id)
    target_action = target_action(decision, action_result, confirmation)

    %__MODULE__{
      confirmation_id: confirmation_id,
      status: :pending,
      target_action: target_action,
      resource_access: resource_access(decision, action_result),
      risk_summary: risk_summary(decision, action_result),
      origin: origin(confirmation, context),
      allowed_actions: allowed_actions(decision),
      render_hints: render_hints(confirmation_id, target_action, decision),
      result_return: result_return(context)
    }
  end

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    status = field(attrs, :status, :pending)

    if status in @statuses do
      {:ok,
       %__MODULE__{
         confirmation_id: field(attrs, :confirmation_id),
         status: status,
         target_action: field(attrs, :target_action),
         resource_access: normalize_list(field(attrs, :resource_access)),
         risk_summary: field(attrs, :risk_summary),
         origin: field(attrs, :origin),
         allowed_actions: normalize_list(field(attrs, :allowed_actions)),
         render_hints: field(attrs, :render_hints, %{}) || %{},
         result_return: field(attrs, :result_return),
         diagnostics: normalize_list(field(attrs, :diagnostics))
       }}
    else
      {:error, {:invalid_approval_handoff_status, status}}
    end
  end

  def new(value), do: {:error, {:invalid_approval_handoff, value}}

  @spec to_map(t() | map() | nil) :: map() | nil
  def to_map(nil), do: nil

  def to_map(%__MODULE__{} = handoff) do
    %{
      confirmation_id: handoff.confirmation_id,
      status: handoff.status,
      target_action: handoff.target_action,
      resource_access: ResourceAccess.to_maps(handoff.resource_access),
      risk_summary: handoff.risk_summary,
      origin: handoff.origin,
      allowed_actions: handoff.allowed_actions,
      render_hints: handoff.render_hints,
      result_return: handoff.result_return,
      diagnostics: handoff.diagnostics
    }
    |> drop_empty_values()
  end

  def to_map(handoff) when is_map(handoff), do: handoff

  @spec lines(t() | map() | nil) :: [String.t()]
  def lines(nil), do: []

  def lines(handoff) do
    handoff = to_map(handoff)

    [
      summary_line(handoff),
      resource_lines(handoff),
      allowed_actions_line(handoff),
      result_return_line(handoff)
    ]
    |> List.flatten()
    |> Enum.reject(&blank?/1)
  end

  defp target_action(decision, action_result, confirmation) do
    action =
      field(confirmation, :target_action) ||
        %{
          name: field(decision_map(decision), :selected_action),
          permission: field(decision_map(decision), :permission),
          execution_mode: field(decision_map(decision), :execution_mode)
        }

    params_summary =
      field(confirmation, :params_summary) ||
        action_result_summary(action_result)

    %{action: action, params_summary: params_summary}
  end

  defp resource_access(decision, action_result) do
    decision_access =
      decision
      |> decision_map()
      |> field(:resource_access, [])

    action_access =
      action_result
      |> action_result_summary()
      |> field(:resource_refs, [])

    ResourceAccess.to_maps(decision_access ++ action_access)
  end

  defp risk_summary(decision, action_result) do
    field(decision_map(decision), :risk_summary) ||
      get_in(action_result, [:permission_decision, :reason])
  end

  defp origin(confirmation, context) do
    field(confirmation, :origin) ||
      %{
        actor:
          context_value(context, :operator_id) || context_value(context, :user_id) || "local",
        channel: context_value(context, :channel) || :unknown,
        surface: context_value(context, :surface),
        session_id: context_value(context, :session_id),
        response_target: context_value(context, :response_target)
      }
      |> drop_empty_values()
  end

  defp allowed_actions(decision) do
    approval_scopes =
      decision
      |> decision_map()
      |> field(:resource_access, [])
      |> Enum.flat_map(&field(&1, :allowed_approval_scopes, []))
      |> Enum.uniq()

    [:approve, :deny, :details] ++ Enum.map(approval_scopes, &%{remember: &1})
  end

  defp render_hints(confirmation_id, target_action, decision) do
    selected_action =
      get_in(target_action, [:action, :name]) ||
        target_action
        |> field(:action, %{})
        |> field(:name)

    %{
      title: "Approval required",
      confirmation_id: confirmation_id,
      target_label: selected_action,
      risk_summary: field(decision_map(decision), :risk_summary)
    }
    |> drop_empty_values()
  end

  defp result_return(context) do
    %{
      same_channel?: true,
      channel: context_value(context, :channel) || :unknown,
      response_target: context_value(context, :response_target)
    }
    |> drop_empty_values()
  end

  defp action_result_summary(%{request: request}) when is_map(request), do: request
  defp action_result_summary(%{install_plan: plan}) when is_map(plan), do: plan
  defp action_result_summary(%{skill_import: import}) when is_map(import), do: import
  defp action_result_summary(%{skill_import_request: import}) when is_map(import), do: import
  defp action_result_summary(%{online_skill_search: search}) when is_map(search), do: search
  defp action_result_summary(%{online_skill_detail: detail}) when is_map(detail), do: detail
  defp action_result_summary(%{online_skill_import: import}) when is_map(import), do: import
  defp action_result_summary(_action_result), do: %{}

  defp summary_line(handoff) do
    target = render_label(handoff) || target_name(field(handoff, :target_action, %{}))

    "Approval: #{field(handoff, :confirmation_id)} status=#{field(handoff, :status)} target=#{target}"
  end

  defp resource_lines(handoff) do
    handoff
    |> field(:resource_access, [])
    |> Enum.map(fn resource ->
      scope = field(resource, :scope, %{}) || %{}
      consumer = field(resource, :downstream_consumer)

      [
        "Resource",
        field(resource, :origin_kind),
        field(resource, :operation_class),
        field(resource, :access_mode),
        "#{field(scope, :kind)}:#{field(scope, :value)}",
        if(consumer, do: "consumer=#{consumer}", else: nil)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
    end)
  end

  defp allowed_actions_line(handoff) do
    actions =
      handoff
      |> field(:allowed_actions, [])
      |> Enum.map(&allowed_action_text/1)
      |> Enum.reject(&blank?/1)
      |> Enum.join(", ")

    if actions == "", do: nil, else: "Allowed: #{actions}"
  end

  defp result_return_line(handoff) do
    result_return = field(handoff, :result_return, %{}) || %{}
    channel = field(result_return, :channel)
    same_channel? = field(result_return, :same_channel?)

    if channel do
      "Result return: same_channel=#{same_channel?} channel=#{channel}"
    end
  end

  defp allowed_action_text(%{remember: scope}), do: "remember #{scope}"
  defp allowed_action_text(%{"remember" => scope}), do: "remember #{scope}"
  defp allowed_action_text(action), do: to_string(action)

  defp render_label(handoff) do
    handoff
    |> field(:render_hints, %{})
    |> field(:target_label)
  end

  defp target_name(%{action: action}), do: field(action, :name)
  defp target_name(%{"action" => action}), do: field(action, :name)
  defp target_name(target), do: field(target, :name)

  defp decision_map(%Decision{} = decision), do: Decision.to_map(decision)
  defp decision_map(decision) when is_map(decision), do: decision
  defp decision_map(_decision), do: %{}

  defp context_value(%{request: request} = context, key) when is_map(request) do
    field(request, key) || context |> Map.delete(:request) |> context_value(key)
  end

  defp context_value(context, key) when is_map(context), do: field(context, key)
  defp context_value(_context, _key), do: nil

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)

  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: list
  defp normalize_list(value), do: [value]

  defp blank?(value), do: value in [nil, ""]

  defp drop_empty_values(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, value} when value == %{} -> true
      {_key, value} when value == [] -> true
      _entry -> false
    end)
  end
end
