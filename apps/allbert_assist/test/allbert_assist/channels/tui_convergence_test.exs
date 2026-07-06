defmodule AllbertAssist.Channels.TUIConvergenceTest do
  @moduledoc """
  v0.62 M6 (ADR 0070 convergence): the enumerated remaining day-to-day read set
  is slash-surfaced, each routing to an already-registered `:internal` read
  that is NOT an intent-router candidate — so an operator inspects
  jobs/objective/trace/registry/memory/health/model without raw `mix`, and the
  TUI adds no agent-routable authority.
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Channels.TUI.SlashCommands

  @moduletag :tui_convergence

  # slash -> backing registered action
  @m6_reads %{
    "/jobs" => "list_jobs",
    "/objective abc123" => "show_objective",
    "/trace" => "trace_summary",
    "/registry" => "registry_health",
    "/memory" => "list_memory_category_summary",
    "/health" => "serve_health",
    "/model-detect" => "first_model_detect"
  }

  test "every new M6 slash routes through Runner to a registered internal read" do
    registered = MapSet.new(Registry.names())

    for {slash, action} <- @m6_reads do
      assert SlashCommands.requires_identity?(slash),
             "#{slash} should route to an action (identity required)"

      assert MapSet.member?(registered, action), "#{action} is not registered"

      capability = elem(Registry.capability(action), 1)
      assert capability.exposure == :internal, "#{action} must be :internal (ADR 0070)"
      assert capability.permission == :read_only, "#{action} must be a read"
    end
  end

  test "the M6 reads are excluded from intent-router candidates (add no agent authority)" do
    agent_names = Registry.agent_capabilities() |> Enum.map(& &1.name) |> MapSet.new()

    for action <- Map.values(@m6_reads) do
      refute MapSet.member?(agent_names, action),
             "#{action} must not be an intent-router candidate"
    end
  end

  test "the canonical command list advertises the new reads" do
    canonical = SlashCommands.canonical_commands()

    for slash <- ["/jobs", "/objective", "/trace", "/registry", "/memory", "/health"] do
      assert slash in canonical, "#{slash} missing from the slash help list"
    end
  end

  test "/objective without an id is a local usage hint, not an action" do
    refute SlashCommands.requires_identity?("/objective")
  end
end
