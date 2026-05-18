defmodule StockSage.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias AllbertAssist.Repo
  alias AllbertAssist.Objectives.Event
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Objectives.Step
  alias Ecto.Adapters.SQL.Sandbox
  alias StockSage.Domain.Analysis
  alias StockSage.Domain.AnalysisDetail
  alias StockSage.Domain.AnalysisQueue
  alias StockSage.Domain.MemoryEntry
  alias StockSage.Domain.Outcome
  alias StockSage.Domain.QueueRun

  using do
    quote do
      alias AllbertAssist.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import StockSage.DataCase
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    reset_plugin_tables()
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  def reset_plugin_tables do
    Repo.delete_all(QueueRun)
    Repo.delete_all(AnalysisDetail)
    Repo.delete_all(Outcome)
    Repo.delete_all(Analysis)
    Repo.delete_all(AnalysisQueue)
    Repo.delete_all(MemoryEntry)
    Repo.delete_all(Event)
    Repo.delete_all(Step)
    Repo.delete_all(Objective)
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
