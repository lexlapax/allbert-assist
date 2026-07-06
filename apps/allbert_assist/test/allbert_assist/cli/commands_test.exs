defmodule AllbertAssist.CLI.CommandsTest do
  @moduledoc """
  v0.62 M3 — the disposition table is complete and spine-only: every operator
  command maps to a registered action, a bounded read, or a dispatcher
  built-in; no command reaches a store directly; dev/CI stays Mix-only. This is
  the `cli-command-inventory-spine-map-001` invariant asserted as data.
  """
  use ExUnit.Case, async: true

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.CLI.Commands

  @moduletag :cli_dispatcher

  test "every :action disposition names a REGISTERED action (spine-routed)" do
    registered = MapSet.new(Registry.names())

    for {path, {:action, name}} <- Commands.operator_table(),
        match?({:action, _}, {:action, name}) do
      assert MapSet.member?(registered, name),
             "command #{inspect(path)} → action #{name} is not registered"
    end
  end

  test "every disposition is one of the allowed kinds (no direct store access)" do
    for {path, disposition} <- Commands.operator_table() do
      case disposition do
        {:action, name} when is_binary(name) -> :ok
        {:read, mod, fun} when is_atom(mod) and is_atom(fun) -> :ok
        :builtin -> :ok
        :mix_only -> :ok
        :retired -> :ok
        other -> flunk("command #{inspect(path)} has an invalid disposition: #{inspect(other)}")
      end
    end
  end

  test "every :read disposition points at an exported zero-arg function" do
    for {path, {:read, mod, fun}} <- Commands.operator_table(),
        match?({:read, _, _}, {:read, mod, fun}) do
      Code.ensure_loaded!(mod)

      assert function_exported?(mod, fun, 0),
             "command #{inspect(path)} → #{inspect(mod)}.#{fun}/0 is not exported"
    end
  end

  @tasks_dir Path.expand("../../../lib/mix/tasks", __DIR__)

  test "the Mix→allbert task mapping classifies every core task" do
    tasks =
      @tasks_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.map(
        &(&1
          |> String.replace_prefix("allbert.", "")
          |> String.replace_suffix(".ex", ""))
      )
      |> MapSet.new()

    mapped = MapSet.new(Map.keys(Commands.task_dispositions()))
    missing = MapSet.difference(tasks, mapped)

    assert MapSet.size(missing) == 0,
           "unmapped core Mix tasks: #{inspect(MapSet.to_list(missing))}"
  end

  test "developer/CI tasks are flagged mix_only" do
    assert Commands.mix_only?("test")
    assert Commands.mix_only?("gen.app")
    refute Commands.mix_only?("ask")
  end
end
