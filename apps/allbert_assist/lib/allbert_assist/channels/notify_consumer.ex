defmodule AllbertAssist.Channels.NotifyConsumer do
  @moduledoc "Signal-driven bridge from durable fan-out lifecycle to ADR 0084 Notify."

  use GenServer

  require Logger

  alias AllbertAssist.Channels.Notify
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias Jido.Signal
  alias Jido.Signal.Bus

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    subscribe_fun = Keyword.get(opts, :subscribe_fun, &Bus.subscribe/2)

    case subscribe_fun.(AllbertAssist.SignalBus, "allbert.objectives.**") do
      {:ok, subscription_id} -> {:ok, %{subscription_id: subscription_id}}
      {:error, reason} -> {:stop, {:notify_subscription_failed, reason}}
    end
  end

  @impl true
  def handle_info({:signal, %Signal{} = signal}, state) do
    try do
      handle_signal(signal)
    rescue
      exception ->
        Logger.warning("channel notify consumer failed: #{Exception.message(exception)}")
    catch
      kind, reason -> Logger.warning("channel notify consumer failed: #{inspect({kind, reason})}")
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_signal(%Signal{type: "allbert.objectives.fanout.joined", data: data}) do
    parent_id = field(data, :parent_id)

    with {:ok, parent} <- Objectives.get_objective(parent_id) do
      summary = compact_report(Fanout.report(parent))

      case Notify.deliver(parent, :completion, summary, event_key: "joined") do
        {:ok, %{state: "delivered"}} -> acknowledge_report(parent)
        _other -> :ok
      end
    end
  end

  defp handle_signal(%Signal{type: "allbert.objectives.run.blocked", data: data}) do
    child_id = field(data, :child_id)

    with {:ok, child} <- Objectives.get_objective(child_id),
         {:ok, parent} <- Objectives.get_objective(child.parent_objective_id) do
      case Objectives.list_steps(child.id) |> List.last() do
        %{confirmation_id: id} when is_binary(id) and id != "" ->
          body =
            "Approval needed for #{child.title}. " <>
              "Reply ALLBERT:SHOW:#{id}, ALLBERT:APPROVE:#{id}, or ALLBERT:DENY:#{id}."

          Notify.deliver(parent, :confirmation_request, body,
            child_objective_id: child.id,
            event_key: "confirmation:#{id}"
          )

        _other ->
          status(parent, child, "blocked")
      end
    end
  end

  defp handle_signal(%Signal{type: type, data: data})
       when type in [
              "allbert.objectives.run.started",
              "allbert.objectives.run.progress",
              "allbert.objectives.run.completed",
              "allbert.objectives.run.failed",
              "allbert.objectives.run.cancelled"
            ] do
    child_id = field(data, :child_id)

    with {:ok, child} <- Objectives.get_objective(child_id),
         {:ok, parent} <- Objectives.get_objective(child.parent_objective_id) do
      status(parent, child, String.replace_prefix(type, "allbert.objectives.run.", ""))
    end
  end

  defp handle_signal(_signal), do: :ok

  defp acknowledge_report(parent) do
    Fanout.acknowledge_report(Fanout.receipt_for(:report, parent.id), %{
      user_id: parent.user_id,
      channel: parent.source_channel,
      thread_id: parent.source_thread_id,
      origin_thread_ref_id: parent.origin_thread_ref_id,
      origin_thread_ref_digest: parent.origin_thread_ref_digest,
      origin_receiver_account_ref: parent.origin_receiver_account_ref
    })
  end

  defp status(parent, child, state) do
    Notify.deliver(parent, :status, "#{parent.title}: #{child.title} — #{state}",
      child_objective_id: child.id,
      event_key: "#{child.id}:#{state}:#{System.unique_integer([:positive])}"
    )
  end

  defp compact_report(report) do
    children =
      report.children
      |> Enum.map_join("; ", fn child -> "#{glyph(child.status)} #{child.title}" end)

    "#{report.title} — #{report.join_outcome}. #{children}"
  end

  defp glyph("completed"), do: "✓"
  defp glyph("cancelled"), do: "⊘"
  defp glyph("failed"), do: "✗"
  defp glyph(_status), do: "•"

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
