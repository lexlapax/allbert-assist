defmodule AllbertAssist.Channels.TUI.Subscriptions do
  @moduledoc """
  Ephemeral fan-out subscriptions for an attached TUI session.

  The subscription dies with the session and carries no unattended delivery
  authority. Objective ownership is re-read before a signal is rendered.
  """

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias Jido.Signal
  alias Jido.Signal.Bus

  @topic "allbert.objectives.**"

  def register(false), do: {:ok, nil}
  def register(true), do: Bus.subscribe(AllbertAssist.SignalBus, @topic)

  def unregister(nil), do: :ok

  def unregister(subscription_id) when is_binary(subscription_id),
    do: Bus.unsubscribe(AllbertAssist.SignalBus, subscription_id)

  def attached_user_signal?(%Signal{data: data}, identity_map) when is_map(data) do
    match?({:ok, _objective}, attached_objective(data, identity_map, %{}))
  end

  def attached_user_signal?(_signal, _identity_map), do: false

  @doc "Build an attached-session delivery from durable objective state."
  def delivery(signal, identity_map, attachment \\ %{})

  def delivery(%Signal{data: data} = signal, identity_map, attachment) when is_map(data) do
    case attached_objective(data, identity_map, attachment) do
      {:ok, objective} ->
        case signal do
          %Signal{type: "allbert.objectives.fanout.joined"} ->
            joined_delivery(objective)

          _other ->
            {:ok, %{lines: [status_line(signal)], parent_id: nil, report: nil}}
        end

      :ignore ->
        :ignore
    end
  end

  def delivery(_signal, _identity_map, _attachment), do: :ignore

  def status_line(%Signal{type: type, data: data}) do
    label = type |> String.replace_prefix("allbert.objectives.", "") |> String.replace(".", " ")
    title = field(data, :title)
    suffix = if is_binary(title) and title != "", do: ": #{title}", else: ""
    "[fan-out] #{label}#{suffix}"
  end

  defp joined_delivery(parent) do
    projection = Fanout.parent_projection(parent)

    if projection.phase == :joined and projection.authoritatively_joined? and
         projection.parent.report_delivery_state == "pending" do
      parent = projection.parent
      report = Fanout.report(projection)

      {:ok,
       %{
         lines: ["[fan-out] fanout joined: #{report.title}", Fanout.format_report(report)],
         parent_id: parent.id,
         report: %{
           receipt: Fanout.receipt_for(:report, parent.id),
           delivery_context: delivery_context(parent)
         }
       }}
    else
      :ignore
    end
  end

  defp attached_objective(data, identity_map, attachment) do
    objective_id = field(data, :parent_id) || field(data, :child_id)

    users =
      identity_map
      |> Enum.filter(&(field(&1, :enabled, true) != false))
      |> MapSet.new(&(field(&1, :user_id) |> to_string()))

    case Objectives.get_objective(objective_id) do
      {:ok, objective} ->
        if MapSet.member?(users, objective.user_id) and attached_origin?(objective, attachment),
          do: {:ok, objective},
          else: :ignore

      _other ->
        :ignore
    end
  end

  defp attached_origin?(_objective, attachment) when map_size(attachment) == 0, do: true

  defp attached_origin?(objective, attachment) do
    channel = field(attachment, :channel)
    receiver_account_ref = field(attachment, :receiver_account_ref)
    parent_id = objective_parent_id(objective)

    scope =
      case field(attachment, :fanouts) do
        fanouts when is_map(fanouts) -> Map.get(fanouts, parent_id)
        _other -> attachment
      end

    thread_id = field(scope || %{}, :thread_id)
    session_id = field(scope || %{}, :session_id)

    is_map(scope) and field(scope, :parent_id) == parent_id and
      objective.source_channel == channel and objective.source_thread_id == thread_id and
      (is_nil(objective.session_id) or objective.session_id == session_id) and
      (is_nil(objective.origin_receiver_account_ref) or
         objective.origin_receiver_account_ref == receiver_account_ref)
  end

  defp objective_parent_id(%{fanout_role: "parent", id: id}), do: id
  defp objective_parent_id(%{fanout_role: "child", parent_objective_id: id}), do: id
  defp objective_parent_id(_objective), do: nil

  defp delivery_context(parent) do
    %{
      user_id: parent.user_id,
      channel: parent.source_channel,
      thread_id: parent.source_thread_id,
      origin_thread_ref_id: parent.origin_thread_ref_id,
      origin_thread_ref_digest: parent.origin_thread_ref_digest,
      origin_receiver_account_ref: parent.origin_receiver_account_ref
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp field(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
