defmodule AllbertAssist.Channels.TUI.Subscriptions do
  @moduledoc """
  Ephemeral fan-out subscriptions for an attached TUI session.

  The subscription dies with the session and carries no unattended delivery
  authority. Objective ownership is re-read before a signal is rendered.
  """

  alias AllbertAssist.Objectives
  alias Jido.Signal
  alias Jido.Signal.Bus

  @topic "allbert.objectives.**"

  def register(false), do: {:ok, nil}
  def register(true), do: Bus.subscribe(AllbertAssist.SignalBus, @topic)

  def unregister(nil), do: :ok

  def unregister(subscription_id) when is_binary(subscription_id),
    do: Bus.unsubscribe(AllbertAssist.SignalBus, subscription_id)

  def attached_user_signal?(%Signal{data: data}, identity_map) when is_map(data) do
    objective_id = field(data, :parent_id) || field(data, :child_id)

    users =
      identity_map
      |> Enum.filter(&(field(&1, :enabled, true) != false))
      |> MapSet.new(&(field(&1, :user_id) |> to_string()))

    case Objectives.get_objective(objective_id) do
      {:ok, objective} -> MapSet.member?(users, objective.user_id)
      _other -> false
    end
  end

  def attached_user_signal?(_signal, _identity_map), do: false

  def status_line(%Signal{type: type, data: data}) do
    label = type |> String.replace_prefix("allbert.objectives.", "") |> String.replace(".", " ")
    title = field(data, :title)
    suffix = if is_binary(title) and title != "", do: ": #{title}", else: ""
    "[fan-out] #{label}#{suffix}"
  end

  defp field(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
