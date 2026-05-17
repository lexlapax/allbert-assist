defmodule AllbertAssist.Objectives.Commands.PruneStale do
  @moduledoc false

  use Jido.Action,
    name: "allbert_objectives_prune_stale",
    description: "Private objective stale-state pruning command."

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Commands
  alias Jido.Agent.Directive
  alias Jido.Signal

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})
    now = Map.get(params, :now) || Map.get(params, "now") || DateTime.utc_now()

    {:ok, count} = Objectives.abandon_stale_objectives(now: now)
    directives = schedule_directives(params)

    Commands.finish(
      :prune_stale,
      {:ok, %{status: :completed, abandoned: count, pruned_at: now, stage: "prune_stale"}},
      Map.put(state, :last_summary, %{abandoned: count, pruned_at: now}),
      directives: directives
    )
  end

  defp schedule_directives(params) do
    case Map.get(params, :schedule_next_ms) || Map.get(params, "schedule_next_ms") do
      delay_ms when is_integer(delay_ms) and delay_ms > 0 ->
        signal =
          Signal.new!("allbert.objectives.engine.prune_stale", %{scheduled: true},
            source: "/allbert/objectives/engine/prune_stale"
          )

        [Directive.schedule(delay_ms, signal)]

      _other ->
        []
    end
  end
end
