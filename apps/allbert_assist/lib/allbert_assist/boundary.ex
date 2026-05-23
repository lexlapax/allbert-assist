defmodule AllbertAssist.Boundary do
  @moduledoc """
  Runtime boundary inventory for the v0.31 consolidation.

  This module is descriptive, not authoritative. It names the public facades,
  planned facades, compatibility shims, and deletion candidates that the
  v0.31 milestones will consolidate. Runtime authority still lives at the
  action runner, Security Central, Settings Central, and the owning contexts.

  Keep this inventory in sync with
  `docs/developer/runtime-boundary-map.md` and
  `docs/plans/v0.31-request-flow.md` as milestones close.
  """

  @type role ::
          :current_facade
          | :active_facade
          | :planned_facade
          | :compatibility_shim
          | :deletion_candidate

  @type subsystem ::
          :actions
          | :app_registry
          | :audit
          | :extension_registry
          | :intent
          | :objectives
          | :paths
          | :persistence
          | :redaction
          | :resources
          | :runtime
          | :security
          | :settings
          | :surface
          | :trace
          | :workspace

  @type entry :: %{
          required(:id) => atom(),
          required(:role) => role(),
          required(:subsystem) => subsystem(),
          optional(:module) => module(),
          optional(:modules) => [module()],
          optional(:target) => module() | atom(),
          optional(:milestone) => atom(),
          optional(:notes) => String.t()
        }

  @current_facades [
    %{
      id: :runtime_submit,
      role: :current_facade,
      subsystem: :runtime,
      module: AllbertAssist.Runtime,
      notes: "Operator/channel entrypoint for user input."
    },
    %{
      id: :action_registry,
      role: :current_facade,
      subsystem: :actions,
      module: AllbertAssist.Actions.Registry,
      notes: "Current runtime-facing action discovery facade."
    },
    %{
      id: :action_runner,
      role: :current_facade,
      subsystem: :actions,
      module: AllbertAssist.Actions.Runner,
      notes: "Current action execution and lifecycle boundary."
    },
    %{
      id: :action_capability_metadata,
      role: :current_facade,
      subsystem: :actions,
      module: AllbertAssist.Actions.Capability,
      notes: "Current descriptive action capability metadata."
    },
    %{
      id: :security_central,
      role: :current_facade,
      subsystem: :security,
      module: AllbertAssist.Security,
      notes: "Permission decision authority."
    },
    %{
      id: :settings_central,
      role: :current_facade,
      subsystem: :settings,
      module: AllbertAssist.Settings,
      notes: "Operator configuration authority."
    },
    %{
      id: :allbert_home_paths,
      role: :current_facade,
      subsystem: :paths,
      module: AllbertAssist.Paths,
      notes: "Current Allbert Home path facade."
    },
    %{
      id: :security_redactor,
      role: :current_facade,
      subsystem: :redaction,
      module: AllbertAssist.Security.Redactor,
      notes: "Current broad redaction helper."
    },
    %{
      id: :trace,
      role: :current_facade,
      subsystem: :trace,
      module: AllbertAssist.Trace,
      notes: "Current trace write/read facade."
    },
    %{
      id: :surface_dsl,
      role: :current_facade,
      subsystem: :surface,
      module: AllbertAssist.Surface,
      notes: "Current Surface DSL and validation facade."
    },
    %{
      id: :workspace_catalog,
      role: :current_facade,
      subsystem: :workspace,
      module: AllbertAssist.Workspace.Catalog,
      target: AllbertAssist.Surface.Catalog,
      notes: "Current workspace tree/catalog facade; M7 converges catalog truth."
    },
    %{
      id: :workspace_context,
      role: :current_facade,
      subsystem: :workspace,
      module: AllbertAssist.Workspace,
      notes: "Workspace context for canvas, ephemeral surfaces, and offline behavior."
    },
    %{
      id: :app_registry,
      role: :current_facade,
      subsystem: :app_registry,
      module: AllbertAssist.App.Registry,
      target: AllbertAssist.Extensions.Registry,
      notes: "Current app contribution registry; M7 adds unified extension facade."
    },
    %{
      id: :plugin_registry,
      role: :current_facade,
      subsystem: :extension_registry,
      module: AllbertAssist.Plugin.Registry,
      target: AllbertAssist.Extensions.Registry,
      notes: "Current plugin contribution registry; M7 adds unified extension facade."
    },
    %{
      id: :resources,
      role: :current_facade,
      subsystem: :resources,
      module: AllbertAssist.Resources,
      notes: "Resource grant and Resource Access facade."
    },
    %{
      id: :objectives,
      role: :current_facade,
      subsystem: :objectives,
      module: AllbertAssist.Objectives,
      notes: "Objective runtime lifecycle facade."
    },
    %{
      id: :intent_engine,
      role: :current_facade,
      subsystem: :intent,
      module: AllbertAssist.Intent.Engine,
      notes: "Current intent routing facade."
    }
  ]

  @planned_facades [
    %{
      id: :boundary_inventory,
      role: :planned_facade,
      subsystem: :runtime,
      module: __MODULE__,
      milestone: :m1,
      notes: "Machine-readable v0.31 boundary map."
    },
    %{
      id: :allbert_action,
      role: :planned_facade,
      subsystem: :actions,
      module: AllbertAssist.Action,
      milestone: :m5,
      notes: "Wrapper macro for registered Allbert capability actions."
    },
    %{
      id: :runtime_response,
      role: :active_facade,
      subsystem: :runtime,
      module: AllbertAssist.Runtime.Response,
      milestone: :m6,
      notes: "Typed completed/denied/confirmation/advisory/error responses."
    },
    %{
      id: :runtime_paths,
      role: :planned_facade,
      subsystem: :paths,
      module: AllbertAssist.Runtime.Paths,
      milestone: :m3,
      notes: "Shared path facade over existing Allbert Home roots."
    },
    %{
      id: :runtime_redactor,
      role: :planned_facade,
      subsystem: :redaction,
      module: AllbertAssist.Runtime.Redactor,
      milestone: :m3,
      notes: "Shared redaction facade over current Security Central policy."
    },
    %{
      id: :runtime_audit,
      role: :planned_facade,
      subsystem: :audit,
      module: AllbertAssist.Runtime.Audit,
      milestone: :m4,
      notes: "Shared audit facade."
    },
    %{
      id: :runtime_persistence,
      role: :planned_facade,
      subsystem: :persistence,
      module: AllbertAssist.Runtime.Persistence,
      milestone: :m4,
      notes: "Shared persistence facade for hybrid metadata/body stores."
    },
    %{
      id: :runtime_trace,
      role: :planned_facade,
      subsystem: :trace,
      module: AllbertAssist.Runtime.Trace,
      milestone: :m4,
      notes: "Shared trace facade over the existing markdown trace writer."
    },
    %{
      id: :extension_registry,
      role: :active_facade,
      subsystem: :extension_registry,
      module: AllbertAssist.Extensions.Registry,
      milestone: :m7,
      notes: "Unified contribution discovery over compiled plugins and apps."
    },
    %{
      id: :surface_catalog,
      role: :active_facade,
      subsystem: :surface,
      module: AllbertAssist.Surface.Catalog,
      milestone: :m7,
      notes: "Single catalog authority for components, primitives, metadata, and renderers."
    },
    %{
      id: :settings_fragment,
      role: :planned_facade,
      subsystem: :settings,
      module: AllbertAssist.Settings.Fragment,
      milestone: :m8,
      notes: "Per-context/app/plugin settings schema fragment contract."
    }
  ]

  @compatibility_shims [
    %{
      id: :permission_gate,
      role: :compatibility_shim,
      subsystem: :security,
      module: AllbertAssist.Security.PermissionGate,
      target: AllbertAssist.Security,
      milestone: :m8,
      notes: "Retire after Security Central parity and eval coverage are explicit."
    },
    %{
      id: :settings_schema_monolith,
      role: :compatibility_shim,
      subsystem: :settings,
      module: AllbertAssist.Settings.Schema,
      target: AllbertAssist.Settings.Fragment,
      milestone: :m8,
      notes: "Split into registered fragments without changing keys/defaults."
    }
  ]

  @deletion_candidates [
    %{
      id: :permission_gate,
      role: :deletion_candidate,
      subsystem: :security,
      module: AllbertAssist.Security.PermissionGate,
      milestone: :m8,
      notes: "Delete only after all callers use Security Central directly."
    }
  ]

  @inventory @current_facades ++ @planned_facades ++ @compatibility_shims ++ @deletion_candidates

  @doc "Return the full v0.31 boundary inventory."
  @spec inventory() :: [entry()]
  def inventory, do: @inventory

  @doc "Return current public facades callers may use today."
  @spec current_facades() :: [entry()]
  def current_facades, do: @current_facades

  @doc "Return planned facades introduced by later v0.31 milestones."
  @spec planned_facades() :: [entry()]
  def planned_facades, do: @planned_facades

  @doc "Return compatibility shims that survive only with explicit exit criteria."
  @spec compatibility_shims() :: [entry()]
  def compatibility_shims, do: @compatibility_shims

  @doc "Return deletion candidates and their owning milestone."
  @spec deletion_candidates() :: [entry()]
  def deletion_candidates, do: @deletion_candidates

  @doc "Return entries for a subsystem."
  @spec by_subsystem(subsystem()) :: [entry()]
  def by_subsystem(subsystem) do
    Enum.filter(@inventory, &(&1.subsystem == subsystem))
  end

  @doc "Return all module atoms referenced by an entry list."
  @spec modules([entry()]) :: [module()]
  def modules(entries \\ @inventory) do
    entries
    |> Enum.flat_map(fn entry ->
      [Map.get(entry, :module) | Map.get(entry, :modules, [])]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc "Return true when a module is currently marked as a public facade."
  @spec current_facade?(module()) :: boolean()
  def current_facade?(module) when is_atom(module) do
    module in modules(@current_facades)
  end
end
