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

  test "M7.1: onboard is a discoverable top-level operator group" do
    assert "onboard" in Commands.groups()
    assert Map.has_key?(Commands.operator_table(), ["onboard"])
  end

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
        {:area, mod} when is_atom(mod) -> :ok
        :builtin -> :ok
        :mix_only -> :ok
        :retired -> :ok
        other -> flunk("command #{inspect(path)} has an invalid disposition: #{inspect(other)}")
      end
    end
  end

  # v0.62 M8.7: an area dispatcher owns its subcommands and is shared release-safe
  # with `mix allbert.<area>`. It must export dispatch/2.
  test "every :area disposition names a module exporting dispatch/2" do
    for {path, {:area, mod}} <- Commands.operator_table(),
        match?({:area, _}, {:area, mod}) do
      Code.ensure_loaded!(mod)

      assert function_exported?(mod, :dispatch, 2),
             "command #{inspect(path)} → #{inspect(mod)}.dispatch/2 is not exported"
    end
  end

  # v0.62 M8.7 (audit blind-spot fix): the cli-mapping doc + task_dispositions
  # advertised ~21 `allbert admin <area>` homes that did NOT exist in the
  # operator table (returned "unknown command"). Enforce that every command home
  # a Mix task maps to actually resolves.
  test "every task_disposition command home resolves in the operator table" do
    homes =
      Commands.task_dispositions()
      |> Map.values()
      |> Enum.flat_map(fn
        {:command, path} -> [path]
        _other -> []
      end)
      |> Enum.uniq()

    table = Commands.operator_table()

    unresolved =
      Enum.reject(homes, fn home ->
        # A home resolves if it (or a longest-prefix of it) is in the table.
        Enum.any?(prefixes(home), &Map.has_key?(table, &1))
      end)

    assert unresolved == [],
           "task_disposition homes with no operator_table entry: #{inspect(unresolved)}"
  end

  defp prefixes(path) do
    for n <- length(path)..1//-1, do: Enum.take(path, n)
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

  # v0.62 M8.15 one-spine (grep-proof regression guard): no CLI area module may
  # call a store/service MUTATOR directly — every mutation must route through a
  # registered action via Runner. Pure reads (get/list/show/status) stay direct
  # and are not in this list. Comment lines are stripped so a doc reference like
  # `Conversations.complete_thread/2` (no call parens) doesn't trip the guard.
  @areas_dir Path.expand("../../../lib/allbert_assist/cli/areas", __DIR__)

  @banned_mutators [
    ~r/Settings\.put\(/,
    ~r/Secrets\.put_secret\(/,
    ~r/Repo\.(insert|update|delete)/,
    ~r/Store\.discard_draft\(/,
    ~r/Session\.clear\(/,
    ~r/Session\.sweep_expired\(/,
    ~r/Conversations\.complete_thread\(/,
    ~r/Jobs\.(pause_job|resume_job|create_job|update_job)\(/,
    ~r/\.run_now\(/,
    ~r/TokenAuth\.(create|rotate|revoke)\(/,
    ~r/ChannelThread\.(link_identity|unlink_identity)\(/,
    ~r/Auth\.ensure_token!\(/,
    ~r/SigningSecret\.(rotate|rotate!)\(/,
    ~r/Scan\.(enable|pause|resume|run_once|ensure_job)\(/
  ]

  test "no CLI area calls a store/service mutator directly (spine-map-001)" do
    offenders =
      @areas_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.flat_map(fn file ->
        code =
          @areas_dir
          |> Path.join(file)
          |> File.read!()
          |> String.split("\n")
          |> Enum.reject(&(&1 |> String.trim_leading() |> String.starts_with?("#")))
          |> Enum.join("\n")

        for pattern <- @banned_mutators, Regex.match?(pattern, code) do
          {file, Regex.source(pattern)}
        end
      end)

    assert offenders == [],
           "CLI area modules must route mutations through Runner, not call stores directly: " <>
             inspect(offenders)
  end
end
