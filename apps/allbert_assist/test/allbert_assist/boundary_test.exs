defmodule AllbertAssist.BoundaryTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Boundary

  @required_current_facade_modules [
    AllbertAssist.Runtime,
    AllbertAssist.Actions.Registry,
    AllbertAssist.Actions.Runner,
    AllbertAssist.Actions.Capability,
    AllbertAssist.Security,
    AllbertAssist.Settings,
    AllbertAssist.Paths,
    AllbertAssist.Security.Redactor,
    AllbertAssist.Trace,
    AllbertAssist.Surface,
    AllbertAssist.Workspace,
    AllbertAssist.Workspace.Catalog,
    AllbertAssist.App.Registry,
    AllbertAssist.Plugin.Registry,
    AllbertAssist.Resources,
    AllbertAssist.Objectives,
    AllbertAssist.Intent.Engine
  ]

  @required_planned_facade_modules [
    AllbertAssist.Boundary,
    AllbertAssist.Action,
    AllbertAssist.Runtime.Response,
    AllbertAssist.Runtime.Paths,
    AllbertAssist.Runtime.Redactor,
    AllbertAssist.Runtime.Audit,
    AllbertAssist.Runtime.Persistence,
    AllbertAssist.Extensions.Registry,
    AllbertAssist.Surface.Catalog,
    AllbertAssist.Settings.Fragment
  ]

  test "current public facade inventory covers the v0.31 M1 subsystems" do
    subsystems = Boundary.current_facades() |> Enum.map(& &1.subsystem) |> MapSet.new()

    for subsystem <- [
          :actions,
          :app_registry,
          :extension_registry,
          :intent,
          :objectives,
          :paths,
          :redaction,
          :resources,
          :runtime,
          :security,
          :settings,
          :surface,
          :trace,
          :workspace
        ] do
      assert MapSet.member?(subsystems, subsystem)
    end
  end

  test "current public facades load and are marked as current facades" do
    current_modules = Boundary.modules(Boundary.current_facades())

    for module <- @required_current_facade_modules do
      assert module in current_modules
      assert Boundary.current_facade?(module)
      assert Code.ensure_loaded?(module)
    end
  end

  test "planned facades pin every later v0.31 target shape" do
    planned_modules = Boundary.modules(Boundary.planned_facades())

    for module <- @required_planned_facade_modules do
      assert module in planned_modules
    end
  end

  test "compatibility shims and deletion candidates have owner milestones" do
    for entry <- Boundary.compatibility_shims() ++ Boundary.deletion_candidates() do
      assert entry.role in [:compatibility_shim, :deletion_candidate]
      assert entry.milestone in [:m7, :m8]
      assert is_binary(entry.notes)
    end
  end

  test "core compatibility shim modules still load while they remain supported" do
    core_shim_modules =
      Boundary.compatibility_shims()
      |> Enum.reject(
        &(&1.id in [:stocksage_app_surface_renderer, :stocksage_workspace_card_adapters])
      )
      |> Boundary.modules()

    for module <- core_shim_modules do
      assert Code.ensure_loaded?(module)
    end
  end

  test "web and plugin renderer shims are tracked without loading them into the core app" do
    shim_modules = Boundary.modules(Boundary.compatibility_shims())

    assert StockSageWeb.Components.SurfaceRenderer in shim_modules
    assert AllbertAssistWeb.Workspace.Components.AnalysisCard in shim_modules

    assert Enum.any?(
             Boundary.compatibility_shims(),
             &(&1.id == :stocksage_workspace_card_adapters and &1.milestone == :m7)
           )
  end

  test "inventory can be filtered by subsystem" do
    assert Enum.any?(Boundary.by_subsystem(:surface), &(&1.id == :surface_dsl))
    assert Enum.any?(Boundary.by_subsystem(:settings), &(&1.id == :settings_fragment))
    assert Enum.any?(Boundary.by_subsystem(:security), &(&1.id == :permission_gate))
  end
end
