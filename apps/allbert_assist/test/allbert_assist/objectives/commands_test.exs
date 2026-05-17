defmodule AllbertAssist.Objectives.CommandsTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Objectives.Commands

  defmodule GoodSubcommand do
    def run(params, context) do
      {:ok,
       %{
         context_seen: Map.get(context, :state),
         last_result: {:ok, %{params: params}}
       }}
    end
  end

  defmodule DirectiveSubcommand do
    def run(_params, _context) do
      {:ok, %{last_result: {:ok, :scheduled}}, %{directive: :schedule}}
    end
  end

  defmodule MissingResultSubcommand do
    def run(_params, _context), do: {:ok, %{patched: true}}
  end

  test "run_subcommand composes direct command patches for orchestrator commands" do
    context = %{state: %{objective_id: "obj_1"}}

    assert {:ok, patch, %{params: %{step_id: "step_1"}}, []} =
             Commands.run_subcommand(GoodSubcommand, %{step_id: "step_1"}, context)

    assert patch.context_seen == %{objective_id: "obj_1"}
  end

  test "run_subcommand preserves subcommand directives" do
    assert {:ok, %{last_result: {:ok, :scheduled}}, :scheduled, [%{directive: :schedule}]} =
             Commands.run_subcommand(DirectiveSubcommand, %{}, %{state: %{}})
  end

  test "run_subcommand rejects patches that do not expose a command result" do
    assert {:error, :missing_command_result} =
             Commands.run_subcommand(MissingResultSubcommand, %{}, %{state: %{}})
  end
end
