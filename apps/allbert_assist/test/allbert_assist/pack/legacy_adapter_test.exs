defmodule AllbertAssist.Pack.LegacyAdapterTest do
  use ExUnit.Case, async: false

  @moduletag :home_fs_serial

  alias AllbertAssist.App.CoreApp
  alias AllbertAssist.DynamicPlugins.ActionsOverlay
  alias AllbertAssist.Intent.Descriptor, as: IntentDescriptor
  alias AllbertAssist.Pack.OTPMetadata.{ApplicationSpec, ReleaseApplication, ReleaseSpec}
  alias AllbertAssist.Pack.Registry
  alias AllbertAssist.Pack.Registry.Candidate

  alias AllbertAssist.Pack.{
    Canonical,
    Kernel,
    LegacyAdapter,
    PathSegment,
    Projection,
    RowSchemas,
    ValidationDiagnostic
  }

  alias AllbertAssist.Pack.Projection.Closed
  alias AllbertAssist.Pack.Residual
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugin.Validator, as: PluginValidator
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures, as: Fixtures
  alias Jido.Signal.Bus

  defmodule OverlayAction do
    use AllbertAssist.Action,
      permission: :read_only,
      exposure: :agent,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required,
      name: "pack_legacy_adapter_overlay_probe",
      description: "Proves that dynamic overlay declarations stay outside Pack capture.",
      category: "test",
      schema: []

    @impl true
    def run(_params, _context), do: {:ok, %{status: :completed}}
  end

  defmodule DuplicateSkillApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :duplicate_skill_test

    @impl true
    def display_name, do: "Duplicate skill test"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def skill_paths do
      [path] = AllbertNotesFiles.Plugin.skill_paths()
      [path, path]
    end
  end

  defmodule MalformedChildPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.malformed_child"

    @impl true
    def display_name, do: "Malformed child"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def validate(_opts), do: :ok
  end

  defmodule RaisingIntentApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :raising_intent_test

    @impl true
    def display_name, do: "Raising intent test"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def validate(_opts), do: :ok

    def intent_descriptors, do: raise("intent descriptor callback failed")
  end

  defmodule ExitingIntentApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :exiting_intent_test

    @impl true
    def display_name, do: "Exiting intent test"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def validate(_opts), do: :ok

    def intent_descriptors, do: exit(:intent_descriptor_callback_exited)
  end

  defmodule MalformedIntentApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :malformed_intent_test

    @impl true
    def display_name, do: "Malformed intent test"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def validate(_opts), do: :ok

    def intent_descriptors, do: :not_a_descriptor_list
  end

  defmodule MixedIntentApp do
    use AllbertAssist.App

    alias AllbertAssist.Actions.Apps.ListApps

    @impl true
    def app_id, do: :mixed_intent_test

    @impl true
    def display_name, do: "Mixed intent test"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def actions, do: [ListApps]

    def intent_descriptors do
      [
        %{
          app_id: app_id(),
          action_name: ListApps.name(),
          label: "List apps"
        },
        %{"malformed" => "descriptor"}
      ]
    end
  end

  defmodule MalformedInternalIntentApp do
    use AllbertAssist.App

    alias AllbertAssist.Actions.Marketplace.ListInstalled

    @impl true
    def app_id, do: :malformed_internal_intent_test

    @impl true
    def display_name, do: "Malformed internal intent test"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def actions, do: [ListInstalled]

    def intent_descriptors do
      [%{app_id: app_id(), action_name: ListInstalled.name(), label: ""}]
    end
  end

  defmodule DuplicateIntentApp do
    use AllbertAssist.App

    alias AllbertAssist.Actions.Apps.ListApps

    @impl true
    def app_id, do: :duplicate_intent_test

    @impl true
    def display_name, do: "Duplicate intent test"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def actions, do: [ListApps]

    def intent_descriptors do
      [
        %{app_id: app_id(), action_name: ListApps.name(), label: "List apps first"},
        %{app_id: app_id(), action_name: ListApps.name(), label: "List apps conflicting"}
      ]
    end
  end

  defmodule ForcedInertRegisteredIntentApp do
    use AllbertAssist.App

    alias AllbertAssist.Actions.Apps.ListApps

    @impl true
    def app_id, do: :forced_inert_registered_intent_test

    @impl true
    def display_name, do: "Forced inert registered intent test"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def actions, do: [ListApps]

    def intent_descriptors do
      [
        %{
          app_id: app_id(),
          action_name: ListApps.name(),
          label: "Forced inert registered action",
          capability: %{registered?: false}
        }
      ]
    end
  end

  defmodule EscalatedInertIntentApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :escalated_inert_intent_test

    @impl true
    def display_name, do: "Escalated inert intent test"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def validate(_opts), do: :ok

    def intent_descriptors do
      [
        %{
          app_id: app_id(),
          action_name: "escalated_inert_action",
          label: "Escalated inert action",
          capability: %{registered?: false, permission: :memory_write}
        }
      ]
    end
  end

  defmodule NonHandoffInertIntentApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :non_handoff_inert_intent_test

    @impl true
    def display_name, do: "Non-handoff inert intent test"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def validate(_opts), do: :ok

    def intent_descriptors do
      [
        %{
          app_id: app_id(),
          action_name: "non_handoff_inert_action",
          label: "Non-handoff inert action",
          capability: %{registered?: false},
          handoff_required?: false
        }
      ]
    end
  end

  defmodule DestinationInertIntentApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :destination_inert_intent_test

    @impl true
    def display_name, do: "Destination-bearing inert intent test"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def validate(_opts), do: :ok

    def intent_descriptors do
      [
        %{
          app_id: app_id(),
          action_name: "destination_inert_action",
          label: "Destination-bearing inert action",
          capability: %{registered?: false},
          destination: "workspace:research"
        }
      ]
    end
  end

  defmodule DuplicateInternalIntentApp do
    use AllbertAssist.App

    alias AllbertAssist.Actions.Marketplace.ListInstalled

    @impl true
    def app_id, do: :duplicate_internal_intent_test

    @impl true
    def display_name, do: "Duplicate internal intent test"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def actions, do: [ListInstalled]

    def intent_descriptors do
      descriptor = %{
        app_id: app_id(),
        action_name: ListInstalled.name(),
        label: "List installed marketplace bundles"
      }

      [descriptor, descriptor]
    end
  end

  defmodule SlowAppRegistry do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(:ok), do: {:ok, %{}}

    @impl true
    def handle_call(:ordered_entries, _from, state), do: {:noreply, state}
  end

  defmodule SnapshotAppRegistry do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :entries),
        name: Keyword.fetch!(opts, :name)
      )
    end

    @impl true
    def init(entries), do: {:ok, entries}

    @impl true
    def handle_call(:ordered_entries, _from, entries), do: {:reply, {:ok, entries}, entries}

    def handle_call(:registered_apps, _from, entries), do: {:reply, entries, entries}

    def handle_call({:app_id_for_action, module}, _from, entries) do
      app_id =
        Enum.find_value(entries, fn entry -> if module in entry.actions, do: entry.app_id end)

      {:reply, app_id, entries}
    end
  end

  defmodule OverlayRacingPluginRegistry do
    use GenServer

    @reserved_overlay :allbert_pack_legacy_adapter_excluded_overlay

    def start_link(opts) do
      GenServer.start_link(__MODULE__, false, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(triggered?), do: {:ok, triggered?}

    @impl true
    def handle_call(:ordered_entries, _from, triggered?) do
      {:reply, {:ok, []}, triggered?}
    end

    def handle_call(:registered_plugins, _from, false) do
      {:ok, _overlay} =
        ActionsOverlay.start_link(name: @reserved_overlay)

      {:reply, [], true}
    end

    def handle_call(:registered_plugins, _from, true), do: {:reply, [], true}
  end

  describe "capture/1 option contract" do
    test "requires one pack_projection option" do
      assert {:error,
              {:capture_failed,
               [
                 %ValidationDiagnostic{
                   schema_version: 1,
                   code: :missing_field,
                   path: [
                     %PathSegment{
                       schema_version: 1,
                       kind: :field,
                       value: "pack_projection"
                     }
                   ],
                   owner: nil,
                   detail: %{field: "pack_projection"}
                 }
               ]}} = LegacyAdapter.capture([])
    end

    test "rejects non-keyword input as a typed error" do
      assert {:error,
              {:capture_failed,
               [
                 %ValidationDiagnostic{
                   schema_version: 1,
                   code: :invalid_type,
                   path: [],
                   owner: nil,
                   detail: %{expected: "keyword_list", actual: "map"}
                 }
               ]}} = LegacyAdapter.capture(%{})
    end

    test "rejects unknown and duplicate options deterministically" do
      assert {:error,
              {:capture_failed,
               [
                 %ValidationDiagnostic{
                   code: :unknown_field,
                   path: [%PathSegment{kind: :field, value: "extra"}],
                   detail: %{field: "extra"}
                 }
               ]}} = LegacyAdapter.capture(pack_projection: [], extra: true)

      assert {:error,
              {:capture_failed,
               [
                 %ValidationDiagnostic{
                   code: :invalid_value,
                   path: [%PathSegment{kind: :field, value: "pack_projection"}],
                   detail: %{reason: :duplicate_option}
                 }
               ]}} =
               LegacyAdapter.capture(pack_projection: [], pack_projection: [])
    end

    test "rejects malformed selector and projection values without raising" do
      assert {:error,
              {:capture_failed,
               [
                 %ValidationDiagnostic{
                   code: :invalid_type,
                   path: [%PathSegment{kind: :field, value: "app"}],
                   detail: %{expected: "keyword_list", actual: "atom"}
                 }
               ]}} = LegacyAdapter.capture(pack_projection: closed_stub(), app: :invalid)

      assert {:error,
              {:capture_failed,
               [
                 %ValidationDiagnostic{
                   code: :invalid_type,
                   path: [%PathSegment{kind: :field, value: "pack_projection"}],
                   detail: %{expected: "closed_pack_projection", actual: "atom"}
                 }
               ]}} = LegacyAdapter.capture(pack_projection: :invalid)
    end

    test "rejects malformed nested registry contexts and overlay selectors" do
      for {key, value} <- [
            {:app, [server: self(), unknown: true]},
            {:plugin, [server: self(), server: self()]},
            {:app, [server: 42]},
            {:app, [server: nil]},
            {:plugin, [server: true]},
            {:app, [server: false]},
            {:plugin, [server: {:via, true, :bad_name}]},
            {:app, [server: {true, node()}]}
          ] do
        assert {:error,
                {:capture_failed,
                 [
                   %ValidationDiagnostic{
                     code: :invalid_type,
                     path: [%PathSegment{kind: :field, value: field}],
                     detail: %{expected: "registry_context", actual: "keyword_list"}
                   }
                 ]}} = LegacyAdapter.capture([{:pack_projection, closed_stub()}, {key, value}])

        assert field == Atom.to_string(key)
      end

      assert {:error,
              {:capture_failed,
               [
                 %ValidationDiagnostic{
                   code: :invalid_type,
                   path: [%PathSegment{kind: :field, value: "actions_overlay"}],
                   detail: %{expected: "gen_server", actual: "integer"}
                 }
               ]}} = LegacyAdapter.capture(pack_projection: closed_stub(), actions_overlay: 42)

      for value <- [nil, true, false, {:via, true, :bad_name}, {true, node()}] do
        assert {:error,
                {:capture_failed,
                 [
                   %ValidationDiagnostic{
                     code: :invalid_type,
                     path: [%PathSegment{kind: :field, value: "actions_overlay"}],
                     detail: %{expected: "gen_server"}
                   }
                 ]}} =
                 LegacyAdapter.capture(pack_projection: closed_stub(), actions_overlay: value)
      end
    end

    test "requires a valid reconciled closed projection envelope" do
      assert {:error,
              {:capture_failed,
               [
                 %ValidationDiagnostic{
                   code: :invalid_type,
                   path: [%PathSegment{kind: :field, value: "pack_projection"}],
                   detail: %{expected: "closed_pack_projection", actual: "list"}
                 }
               ]}} = LegacyAdapter.capture(pack_projection: [])

      assert {:error,
              {:capture_failed,
               [
                 %ValidationDiagnostic{
                   code: :invalid_value,
                   path: [%PathSegment{kind: :field, value: "pack_projection"}],
                   detail: %{reason: :unreconciled_pack_projection}
                 }
               ]}} = LegacyAdapter.capture(pack_projection: closed_stub())
    end

    test "returns a typed error when a selected registry is unavailable" do
      assert Process.whereis(:pack_legacy_adapter_missing_registry) == nil

      assert {:error,
              {:capture_failed,
               [
                 %ValidationDiagnostic{
                   schema_version: 1,
                   code: :invalid_value,
                   path: [],
                   owner: nil,
                   detail: %{reason: :registry_unavailable}
                 }
               ]}} =
               LegacyAdapter.capture(
                 pack_projection: closed_projection(),
                 app: [server: :pack_legacy_adapter_missing_registry]
               )
    end

    test "a slow but live selected App registry cannot collapse to stable empty state" do
      context = Fixtures.start_isolated_registries(:pack_legacy_adapter_slow_app_registry)
      slow_registry = :pack_legacy_adapter_slow_live_app_registry

      start_supervised!({SlowAppRegistry, name: slow_registry})
      context = Keyword.put(context, :app, server: slow_registry)

      assert {:error,
              {:capture_failed,
               [
                 %ValidationDiagnostic{
                   schema_version: 1,
                   code: :invalid_value,
                   path: [],
                   owner: nil,
                   detail: %{reason: :registry_unavailable}
                 }
               ]}} =
               LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])

      assert Process.alive?(Process.whereis(slow_registry))
    end
  end

  describe "capture/1 private shipped registry projection" do
    test "captures the full frozen action declaration and effective-binding denominators" do
      context = Fixtures.start_shipped_registries(:pack_legacy_adapter)

      assert {:ok,
              %Candidate{
                schema_version: 1,
                contributions: contributions,
                action_bindings: action_bindings,
                compatibility_aliases: aliases,
                compatibility_diagnostics: diagnostics
              }} = LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])

      assert Enum.count(contributions, &(&1.source_lane == :native)) == 2
      assert Enum.count(contributions, &(&1.source_lane == :legacy_plugin)) == 13

      action_rows = Enum.flat_map(contributions, & &1.callbacks.actions)
      assert length(action_rows) == 284
      assert length(action_bindings) == 281
      assert Enum.map(action_bindings, & &1.legacy_index) == Enum.to_list(1..281)
      assert Enum.map(action_bindings, & &1.registry_order) == Enum.to_list(1..281)
      assert Enum.count(action_bindings, &(&1.source_lane == :native_static)) == 244
      assert Enum.count(action_bindings, &(&1.source_lane == :legacy_plugin)) == 37

      assert length(aliases) == 3
      assert Enum.count(action_rows, &(&1.order.namespace == :alias_target)) == 3
      assert Enum.count(action_rows, &(&1.order.namespace == :registry_order)) == 281

      assert Enum.map(
               action_rows -- Enum.filter(action_rows, &(&1.order.namespace == :alias_target)),
               & &1.order.value
             ) ==
               Enum.to_list(1..281)

      assert Enum.count(diagnostics, &(&1.code == :child_spec)) == 3

      skill_rows =
        for contribution <- contributions,
            row <- contribution.callbacks.skill_roots do
          {contribution.owner.id, row}
        end

      assert [
               {"allbert.notes_files",
                %AllbertAssist.Pack.Row{
                  kind: :skill_roots,
                  owner_id: "allbert.notes_files",
                  identity: %{namespace: :root_id, value: "notes_files:skills"},
                  order: %{namespace: :lexical, value: "notes_files:skills"},
                  payload: %{
                    "root_id" => "notes_files:skills",
                    "relative_path" => "plugins/allbert.notes_files/skills",
                    "trust_policy" => "trusted",
                    "projection_sha256" => notes_digest
                  },
                  source_authority: %{}
                }},
               {"stocksage",
                %AllbertAssist.Pack.Row{
                  kind: :skill_roots,
                  owner_id: "stocksage",
                  identity: %{namespace: :root_id, value: "stocksage:skills"},
                  order: %{namespace: :lexical, value: "stocksage:skills"},
                  payload: %{
                    "root_id" => "stocksage:skills",
                    "relative_path" => "plugins/stocksage/skills",
                    "trust_policy" => "trusted",
                    "projection_sha256" => stocksage_digest
                  },
                  source_authority: %{}
                }}
             ] = Enum.sort_by(skill_rows, &elem(&1, 0))

      assert notes_digest =~ ~r/^[0-9a-f]{64}$/
      assert stocksage_digest =~ ~r/^[0-9a-f]{64}$/

      row_counts =
        for callback <- [
              :apps,
              :actions,
              :settings_fragments,
              :channels,
              :surfaces,
              :skill_roots,
              :intent_descriptors
            ],
            into: %{} do
          {callback,
           Enum.sum(Enum.map(contributions, &length(Map.fetch!(&1.callbacks, callback))))}
        end

      assert row_counts == %{
               apps: 6,
               actions: 284,
               settings_fragments: 56,
               channels: 8,
               surfaces: 28,
               skill_roots: 2,
               intent_descriptors: 61
             }

      intent_rows = Enum.flat_map(contributions, & &1.callbacks.intent_descriptors)
      research_intent_ids = ["allbert_research:research", "allbert_research:summarize_url"]

      research_inert_rows =
        intent_rows
        |> Enum.filter(&(&1.identity.value in research_intent_ids))
        |> Enum.sort_by(& &1.identity.value)

      assert Enum.map(research_inert_rows, & &1.identity.value) == research_intent_ids

      assert Enum.all?(research_inert_rows, fn row ->
               capability = row.source_authority["capability"]

               row.owner_id == "allbert.research" and
                 row.source_authority["source"] == "app" and
                 row.source_authority["destination"] == nil and
                 row.source_authority["handoff_required"] == true and
                 capability == %{
                   "name" => row.source_authority["action_name"],
                   "module" => nil,
                   "registered?" => false,
                   "permission" => "read_only",
                   "exposure" => "agent",
                   "execution_mode" => "read_only",
                   "skill_backed?" => false,
                   "confirmation" => "not_required",
                   "resumable?" => false,
                   "retry_safety" => nil,
                   "app_id" => "allbert_research",
                   "plugin_id" => nil
                 }
             end)

      research_action_names = ["research", "summarize_url"]
      refute Enum.any?(action_bindings, &(&1.name in research_action_names))
      refute Enum.any?(action_rows, &(&1.payload["name"] in research_action_names))
      refute Enum.any?(aliases, &(&1.target.identity in research_action_names))

      intent_result =
        IntentDescriptor.normalize_many(
          CoreApp.intent_descriptors(),
          [
            app_id: :allbert,
            plugin_id: nil,
            source: :app,
            source_module: CoreApp,
            actions_overlay: :allbert_pack_legacy_adapter_excluded_overlay
          ] ++ context
        )

      assert Enum.map(intent_result.diagnostics, & &1.reason) == [
               {:action_not_agent_exposed, "list_installed_marketplace_bundles"},
               {:action_not_agent_exposed, "rollback_marketplace_install"},
               {:action_not_agent_exposed, "verify_marketplace_bundle_hash"}
             ]

      app_rows = Enum.flat_map(contributions, & &1.callbacks.apps)

      assert Enum.sum(Enum.map(app_rows, &length(&1.source_authority["actions"]))) == 23

      assert Enum.sum(Enum.map(app_rows, &length(&1.source_authority["intent_descriptor_refs"]))) ==
               61

      assert Enum.sum(Enum.map(app_rows, &length(&1.source_authority["surface_refs"]))) == 28

      notes_app = Enum.find(app_rows, &(&1.identity.value == "notes_files"))
      stocksage_app = Enum.find(app_rows, &(&1.identity.value == "stocksage"))

      assert notes_app.source_authority["skill_root_refs"] == [
               %{
                 "owner_id" => "allbert.notes_files",
                 "root_id" => "notes_files:skills",
                 "projection_sha256" => notes_digest
               }
             ]

      assert stocksage_app.source_authority["skill_root_refs"] == [
               %{
                 "owner_id" => "stocksage",
                 "root_id" => "stocksage:skills",
                 "projection_sha256" => stocksage_digest
               }
             ]

      for callback <- [
            :settings_migrations,
            :home_roots,
            :jobs,
            :stores,
            :prompt_rules,
            :cli_groups,
            :release_assets,
            :test_lanes
          ] do
        assert Enum.all?(contributions, &(Map.fetch!(&1.callbacks, callback) == []))
      end
    end

    test "selected dynamic overlay entries cannot change candidate data" do
      context = Fixtures.start_shipped_registries(:pack_legacy_adapter_overlay)
      overlay = :"pack_legacy_adapter_overlay_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec(
          {ActionsOverlay, name: overlay},
          id: overlay
        )
      )

      assert :ok =
               ActionsOverlay.register_many(
                 [
                   %{
                     name: OverlayAction.name(),
                     module: OverlayAction,
                     slug: "pack-legacy-adapter-overlay-probe",
                     revision: "1",
                     exposure: :agent
                   }
                 ],
                 server: overlay,
                 existing_names: []
               )

      projection = closed_projection()
      assert {:ok, baseline} = LegacyAdapter.capture([{:pack_projection, projection} | context])

      selected_context = Keyword.put(context, :actions_overlay, overlay)

      assert OverlayAction in AllbertAssist.Actions.Registry.modules(selected_context)

      assert {:ok, ^baseline} =
               LegacyAdapter.capture([{:pack_projection, projection} | selected_context])
    end

    test "rejects capture whenever the reserved exclusion overlay exists" do
      context = Fixtures.start_isolated_registries(:pack_legacy_adapter_reserved_overlay)
      reserved = :allbert_pack_legacy_adapter_excluded_overlay
      assert Process.whereis(reserved) == nil

      start_supervised!(
        Supervisor.child_spec(
          {ActionsOverlay, name: reserved},
          id: reserved
        )
      )

      assert_unstable_capture(context)
    end

    test "rejects a reserved exclusion overlay created during action observation" do
      context = Fixtures.start_isolated_registries(:pack_legacy_adapter_overlay_race)
      reserved = :allbert_pack_legacy_adapter_excluded_overlay
      registry = :pack_legacy_adapter_overlay_racing_plugin_registry
      assert Process.whereis(reserved) == nil

      start_supervised!({OverlayRacingPluginRegistry, name: registry})
      context = Keyword.put(context, :plugin, server: registry)

      assert_unstable_capture(context)
      assert is_pid(Process.whereis(reserved))
    end

    test "rejects dangling, mismatched, and duplicate skill-root declarations" do
      {:ok, base_entry} = PluginValidator.validate_module(AllbertNotesFiles.Plugin)
      [notes_path] = AllbertNotesFiles.Plugin.skill_paths()
      [stocksage_path] = StockSage.Plugin.skill_paths()

      cases = [
        {:dangling, %{base_entry | skill_paths: []}, AllbertNotesFiles.App},
        {:mismatched, %{base_entry | skill_paths: [stocksage_path]}, AllbertNotesFiles.App},
        {:duplicate,
         %{
           base_entry
           | apps: [DuplicateSkillApp],
             skill_paths: [notes_path, notes_path]
         }, DuplicateSkillApp}
      ]

      for {tag, entry, app_module} <- cases do
        context = Fixtures.start_isolated_registries("pack_legacy_adapter_skill_error_#{tag}")
        Fixtures.register_plugin!(context, entry)
        Fixtures.register_app!(context, app_module)

        assert {:error,
                {:capture_failed,
                 [
                   %ValidationDiagnostic{
                     schema_version: 1,
                     code: :invalid_value,
                     path: [],
                     owner: nil,
                     detail: %{reason: :unstable_registry_capture}
                   }
                 ]}} =
                 LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])
      end
    end

    test "captures disabled child declarations as inert contributions and exact evidence" do
      context = Fixtures.start_isolated_registries(:pack_legacy_adapter_disabled_plugin)
      {:ok, disabled} = PluginValidator.validate_module(StockSage.Plugin, status: :disabled)
      Fixtures.register_plugin!(context, disabled)

      plugin_server = context |> Keyword.fetch!(:plugin) |> Keyword.fetch!(:server)
      before = :sys.get_state(plugin_server)

      assert [] = PluginRegistry.registered_plugins(server: plugin_server)
      assert {:ok, [^disabled]} = PluginRegistry.ordered_entries(server: plugin_server)

      assert {:ok, %Candidate{} = candidate} =
               LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])

      assert [contribution] =
               Enum.filter(candidate.contributions, &(&1.owner.kind == :legacy_plugin))

      assert contribution.owner.id == "stocksage"
      assert contribution.implementation_module == StockSage.Plugin
      assert contribution.compatibility.enabled == false
      assert Enum.all?(contribution.callbacks, fn {_callback, rows} -> rows == [] end)

      assert [
               %AllbertAssist.Pack.CompatibilityDiagnostic{
                 schema_version: 1,
                 code: :disabled_plugin,
                 severity: :warning,
                 path: [
                   %PathSegment{schema_version: 1, kind: :field, value: "plugins"},
                   %PathSegment{schema_version: 1, kind: :identity, value: "stocksage"},
                   %PathSegment{schema_version: 1, kind: :field, value: "status"}
                 ],
                 owner: %AllbertAssist.Pack.OwnerRef{
                   schema_version: 1,
                   kind: :legacy_plugin,
                   id: "stocksage"
                 },
                 detail: %{source: :shipped, status: :disabled}
               }
             ] = candidate.compatibility_diagnostics

      assert {:ok, _snapshot} = Canonical.build_snapshot(candidate, :shadow)
      assert :sys.get_state(plugin_server) == before
    end

    test "disabled entries emit exact evidence even when their child declaration is ignored" do
      context = Fixtures.start_isolated_registries(:pack_legacy_adapter_disabled_ignore)

      {:ok, disabled} =
        PluginValidator.validate_module(AllbertArtifacts.Plugin, status: :disabled)

      assert disabled.children == :ignore
      Fixtures.register_plugin!(context, disabled)

      assert {:ok, %Candidate{} = candidate} =
               LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])

      assert [%AllbertAssist.Pack.CompatibilityDiagnostic{code: :disabled_plugin}] =
               candidate.compatibility_diagnostics

      assert [contribution] =
               Enum.filter(candidate.contributions, &(&1.owner.id == "allbert.artifacts"))

      assert contribution.compatibility.enabled == false
      assert Enum.all?(contribution.callbacks, fn {_callback, rows} -> rows == [] end)
    end

    test "rejects stale App state declared by a disabled plugin instead of reassigning it" do
      context = Fixtures.start_isolated_registries(:pack_legacy_adapter_disabled_app_leak)

      {:ok, disabled} =
        PluginValidator.validate_module(AllbertArtifacts.Plugin, status: :disabled)

      Fixtures.register_plugin!(context, disabled)
      Fixtures.register_app!(context, AllbertArtifacts.App)

      assert {:error,
              {:capture_failed,
               [
                 %ValidationDiagnostic{
                   schema_version: 1,
                   code: :invalid_value,
                   path: [],
                   owner: nil,
                   detail: %{reason: :unstable_registry_capture}
                 }
               ]}} =
               LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])
    end

    test "rejects registry entries whose status cannot produce exact compatibility evidence" do
      context = Fixtures.start_isolated_registries(:pack_legacy_adapter_invalid_plugin_status)
      {:ok, entry} = PluginValidator.validate_module(StockSage.Plugin, status: :disabled)
      Fixtures.register_plugin!(context, %{entry | status: :invalid})

      assert {:error,
              {:capture_failed,
               [
                 %ValidationDiagnostic{
                   schema_version: 1,
                   code: :invalid_value,
                   path: [],
                   owner: nil,
                   detail: %{reason: :unstable_registry_capture}
                 }
               ]}} =
               LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])
    end

    test "rejects raised or malformed intent callbacks without returning a partial candidate" do
      for module <- [
            RaisingIntentApp,
            ExitingIntentApp,
            MalformedIntentApp,
            MixedIntentApp,
            MalformedInternalIntentApp,
            DuplicateIntentApp,
            ForcedInertRegisteredIntentApp,
            EscalatedInertIntentApp,
            NonHandoffInertIntentApp,
            DestinationInertIntentApp,
            DuplicateInternalIntentApp
          ] do
        context =
          Fixtures.start_isolated_registries("pack_legacy_adapter_intent_#{inspect(module)}")

        Fixtures.register_app!(context, module)

        assert_unstable_capture(context)
      end
    end

    test "rejects invalid observed Plugin Entry carriers before adaptation" do
      {:ok, base_entry} = PluginValidator.validate_module(AllbertArtifacts.Plugin)

      cases = [
        {:invalid_trust, %{base_entry | trust_status: :bogus}},
        {:blank_id, %{base_entry | plugin_id: ""}},
        {:padded_id, %{base_entry | plugin_id: " allbert.artifacts "}},
        {:invalid_source_atom, %{base_entry | source: :bogus}},
        {:invalid_source_type, %{base_entry | source: "shipped", status: :disabled}},
        {:invalid_module_type, %{base_entry | module: "AllbertArtifacts.Plugin"}},
        {:unloaded_module, %{base_entry | module: AllbertAssist.UnloadedPluginFixture}},
        {:mismatched_module, %{base_entry | module: AllbertResearch.Plugin}},
        {:invalid_apps_type, %{base_entry | apps: :not_a_list}},
        {:unknown_field, Map.put(base_entry, :future_authority, :must_not_be_dropped)}
      ]

      for {tag, entry} <- cases do
        context = Fixtures.start_isolated_registries("pack_legacy_adapter_carrier_#{tag}")
        Fixtures.register_plugin!(context, entry)

        assert_unstable_capture(context)
      end
    end

    test "rejects behaviour-tagged App and Plugin carriers with missing required exports" do
      missing_app =
        load_incomplete_behaviour_module!(
          Module.concat(__MODULE__, MissingExportAppFixture),
          AllbertAssist.App,
          [
            app_id: 0,
            display_name: 0,
            version: 0,
            validate: 1,
            child_spec: 1,
            agents: 0,
            actions: 0,
            signals: 0,
            skill_paths: 0,
            settings_schema: 0,
            surfaces: 0
          ],
          {:surfaces, 0}
        )

      app_context = Fixtures.start_isolated_registries(:pack_legacy_adapter_missing_app_export)
      Fixtures.register_app!(app_context, AllbertArtifacts.App)
      app_opts = Keyword.fetch!(app_context, :app)
      assert {:ok, [app_entry]} = AllbertAssist.App.Registry.ordered_entries(app_opts)

      app_registry = :pack_legacy_adapter_missing_export_app_registry

      start_supervised!(
        {SnapshotAppRegistry, name: app_registry, entries: [%{app_entry | module: missing_app}]}
      )

      assert_unstable_capture(Keyword.put(app_context, :app, server: app_registry))

      missing_plugin =
        load_incomplete_behaviour_module!(
          Module.concat(__MODULE__, MissingExportPluginFixture),
          AllbertAssist.Plugin,
          [
            plugin_id: 0,
            display_name: 0,
            version: 0,
            validate: 1,
            apps: 0,
            channels: 0,
            actions: 0,
            skill_paths: 0,
            settings_schema: 0,
            release_availability: 0,
            child_spec: 1
          ],
          {:release_availability, 0}
        )

      plugin_context =
        Fixtures.start_isolated_registries(:pack_legacy_adapter_missing_plugin_export)

      {:ok, plugin_entry} = PluginValidator.validate_module(AllbertArtifacts.Plugin)

      Fixtures.register_plugin!(
        plugin_context,
        %{plugin_entry | source: :project, module: missing_plugin}
      )

      assert_unstable_capture(plugin_context)
    end

    test "rejects unknown observed App entry fields instead of dropping future authority" do
      context = Fixtures.start_isolated_registries(:pack_legacy_adapter_unknown_app_field)
      Fixtures.register_app!(context, AllbertArtifacts.App)

      app_opts = Keyword.fetch!(context, :app)
      assert {:ok, [entry]} = AllbertAssist.App.Registry.ordered_entries(app_opts)

      forged = Map.put(entry, :future_authority, :must_not_be_dropped)
      server = :pack_legacy_adapter_forged_app_registry

      start_supervised!({SnapshotAppRegistry, name: server, entries: [forged]})
      context = Keyword.put(context, :app, server: server)

      assert_unstable_capture(context)
    end

    test "preserves integer App child ids accepted by the frozen projection" do
      context = Fixtures.start_isolated_registries(:pack_legacy_adapter_integer_child_id)
      Fixtures.register_app!(context, AllbertArtifacts.App)

      app_opts = Keyword.fetch!(context, :app)
      assert {:ok, [entry]} = AllbertAssist.App.Registry.ordered_entries(app_opts)

      server = :pack_legacy_adapter_integer_child_registry
      start_supervised!({SnapshotAppRegistry, name: server, entries: [%{entry | child_id: 42}]})
      context = Keyword.put(context, :app, server: server)

      assert {:ok, %Candidate{} = candidate} =
               LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])

      assert [app_row] =
               for(
                 contribution <- candidate.contributions,
                 row <- contribution.callbacks.apps,
                 row.identity.value == "allbert_artifacts",
                 do: row
               )

      assert app_row.source_authority["child_id"] == 42
    end

    test "adapts enabled moduleless skill manifests as data-only declared contributions" do
      context = Fixtures.start_isolated_registries(:pack_legacy_adapter_declared_manifest)

      skill_paths = [
        declared_plugin_root("example.skills"),
        Path.join([declared_plugin_root("example.skills"), "arbitrary", "toolkit"])
      ]

      entry = moduleless_skill_entry(skill_paths: skill_paths)
      Fixtures.register_plugin!(context, entry)

      assert {:ok, %Candidate{} = candidate} =
               LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])

      assert [contribution] =
               Enum.filter(candidate.contributions, &(&1.owner.id == "example.skills"))

      assert contribution.implementation_module == nil
      assert contribution.descriptor == nil
      assert contribution.owner.kind == :declared_pack
      assert contribution.owner.application == nil
      assert contribution.source_lane == :declared
      assert contribution.owner_order.namespace == :declared_pack
      assert contribution.owner_order.value == "example.skills"
      assert contribution.compatibility.kind == :declared
      assert contribution.compatibility.legacy_id == nil
      assert contribution.compatibility.alias_of == nil
      assert contribution.compatibility.trust == :pending
      assert contribution.compatibility.enabled == true

      assert Enum.all?(contribution.callbacks, fn
               {:skill_roots, _rows} -> true
               {_callback, rows} -> rows == []
             end)

      rows = contribution.callbacks.skill_roots

      assert Enum.map(rows, &Map.drop(&1.payload, ["projection_sha256"])) == [
               %{
                 "relative_path" => "plugins/example.skills",
                 "root_id" => "example.skills:plugins/example.skills",
                 "trust_policy" => "pending"
               },
               %{
                 "relative_path" => "plugins/example.skills/arbitrary/toolkit",
                 "root_id" => "example.skills:plugins/example.skills/arbitrary/toolkit",
                 "trust_policy" => "pending"
               }
             ]

      assert Enum.all?(rows, &(&1.payload["projection_sha256"] =~ ~r/^[0-9a-f]{64}$/))

      assert Enum.all?(contribution.callbacks.skill_roots, fn row ->
               row.owner_id == "example.skills" and
                 row.identity == %{namespace: :root_id, value: row.payload["root_id"]} and
                 row.order == %{namespace: :lexical, value: row.payload["root_id"]}
             end)

      assert [] == candidate.compatibility_diagnostics
      assert {:ok, _snapshot} = Canonical.build_snapshot(candidate, :shadow)
    end

    test "keeps disabled moduleless manifests inert with exact declared-owner evidence" do
      context = Fixtures.start_isolated_registries(:pack_legacy_adapter_disabled_declared)

      entry =
        moduleless_skill_entry(
          status: :disabled,
          skill_paths: [declared_skill_path("example.skills", "disabled")]
        )

      Fixtures.register_plugin!(context, entry)

      assert {:ok, %Candidate{} = candidate} =
               LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])

      assert [contribution] =
               Enum.filter(candidate.contributions, &(&1.owner.id == "example.skills"))

      assert contribution.owner.kind == :declared_pack
      assert contribution.compatibility.enabled == false
      assert Enum.all?(contribution.callbacks, fn {_callback, rows} -> rows == [] end)

      assert [diagnostic] = candidate.compatibility_diagnostics
      assert diagnostic.code == :disabled_plugin
      assert diagnostic.owner.kind == :declared_pack
      assert diagnostic.owner.id == "example.skills"
      assert diagnostic.detail == %{source: :home, status: :disabled}
      assert {:ok, _snapshot} = Canonical.build_snapshot(candidate, :shadow)
    end

    test "rejects code-bearing moduleless entries and malformed declared skill roots" do
      base = moduleless_skill_entry()

      invariant_cases = [
        {:shipped_source, %{base | source: :shipped}},
        {:app_code, %{base | apps: [MixedIntentApp]}},
        {:action_code, %{base | actions: [AllbertAssist.Actions.Apps.ListApps]}},
        {:channel_code, %{base | channels: [%{channel_id: :forbidden}]}},
        {:settings_code, %{base | settings_schema: [%{key: "plugins.example.enabled"}]}},
        {:child_code, %{base | children: %{id: :forbidden, start: {Agent, :start_link, [[]]}}}},
        {:outside_root, %{base | skill_paths: [Path.join(System.tmp_dir!(), "skills")]}},
        {:duplicate_root,
         %{
           base
           | skill_paths: [
               declared_skill_path("example.skills", "duplicate"),
               declared_skill_path("example.skills", "duplicate")
             ]
         }}
      ]

      for {tag, entry} <- invariant_cases do
        context = Fixtures.start_isolated_registries("pack_legacy_adapter_declared_#{tag}")
        Fixtures.register_plugin!(context, entry)

        assert_unstable_capture(context)
      end
    end

    test "rejects malformed frozen child specs as unstable data without raising" do
      malformed_specs = [
        %{id: "bad-start", start: :not_an_mfa},
        %{id: "bad-restart", restart: :sometimes},
        %{id: "bad-shutdown", shutdown: -1},
        %{id: "bad-type", type: :daemon},
        %{id: self()},
        %{
          id: "bad-arg-key",
          start: {Agent, :start_link, [[%{{:tuple, :key} => "value"}]]}
        },
        {MalformedChildPlugin, []}
      ]

      for {children, index} <- Enum.with_index(malformed_specs, 1) do
        context = Fixtures.start_isolated_registries("pack_legacy_adapter_bad_child_#{index}")

        entry = %PluginEntry{
          plugin_id: "example.malformed_child_#{index}",
          display_name: "Malformed child #{index}",
          version: "1.0.0",
          kind: "runtime",
          source: :shipped,
          status: :enabled,
          trust_status: :trusted,
          module: MalformedChildPlugin,
          children: children
        }

        Fixtures.register_plugin!(context, entry)

        assert {:error,
                {:capture_failed,
                 [
                   %ValidationDiagnostic{
                     schema_version: 1,
                     code: :invalid_value,
                     path: [],
                     owner: nil,
                     detail: %{reason: :unstable_registry_capture}
                   }
                 ]}} =
                 LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])
      end
    end

    @tag timeout: 120_000
    test "the complete captured candidate finalizes through the production canonical boundary" do
      context = Fixtures.start_shipped_registries(:pack_legacy_adapter_finalize)

      assert {:ok, %Candidate{} = candidate} =
               LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])

      for contribution <- candidate.contributions,
          callback <- RowSchemas.callback_order(),
          row <- Map.fetch!(contribution.callbacks, callback) do
        try do
          authority = RowSchemas.alias_authority_projection!(row, contribution)
          assert is_map(authority)

          assert [] == unsupported_json_values(authority),
                 "unsupported canonical authority owner=#{contribution.owner.id} " <>
                   "callback=#{callback} identity=#{inspect(row.identity)}"
        rescue
          error ->
            flunk(
              "row rejected owner=#{contribution.owner.id} callback=#{callback} " <>
                "identity=#{inspect(row.identity)}: #{Exception.message(error)}"
            )
        end
      end

      for action <- candidate.action_bindings do
        assert [] == unsupported_json_values(action.normalized_capability.notes),
               "unsupported action notes module=#{inspect(action.module)}"
      end

      registry = :"pack_legacy_adapter_registry_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec(
          {Registry, name: registry, coordinator: self()},
          id: registry
        )
      )

      assert {:ok, _snapshot} = Canonical.build_snapshot(candidate, :shadow)
      assert {:ok, snapshot} = Registry.finalize(candidate, server: registry)
      assert snapshot.behavior_digest =~ ~r/^[0-9a-f]{64}$/
      assert {:ok, bytes} = Canonical.snapshot_bytes(snapshot)
      assert is_binary(bytes) and byte_size(bytes) > 0
      assert {:ok, ^snapshot} = Registry.finalize(candidate, server: registry)
    end

    test "capture leaves registries, signals, settings cache, and child supervisors untouched" do
      context = Fixtures.start_shipped_registries(:pack_legacy_adapter_read_only)
      app_opts = Keyword.fetch!(context, :app)
      plugin_opts = Keyword.fetch!(context, :plugin)

      for pattern <- ["allbert.app.**", "allbert.plugin.**", "allbert.action.**"] do
        assert {:ok, _subscription} = Bus.subscribe(AllbertAssist.SignalBus, pattern)
      end

      before = %{
        apps: AllbertAssist.App.Registry.registered_apps(app_opts),
        plugins: AllbertAssist.Plugin.Registry.registered_plugins(plugin_opts),
        app_diagnostics: AllbertAssist.App.Registry.diagnostics(app_opts),
        plugin_diagnostics: AllbertAssist.Plugin.Registry.diagnostics(plugin_opts),
        settings_cache:
          :persistent_term.get(
            {AllbertAssist.Settings.Fragments, :default_composition},
            :not_cached
          ),
        app_children: DynamicSupervisor.which_children(AllbertAssist.App.DynamicSupervisor),
        plugin_children: DynamicSupervisor.which_children(AllbertAssist.Plugin.ChildSupervisor)
      }

      assert {:ok, %Candidate{}} =
               LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])

      assert before.apps == AllbertAssist.App.Registry.registered_apps(app_opts)
      assert before.plugins == AllbertAssist.Plugin.Registry.registered_plugins(plugin_opts)
      assert before.app_diagnostics == AllbertAssist.App.Registry.diagnostics(app_opts)
      assert before.plugin_diagnostics == AllbertAssist.Plugin.Registry.diagnostics(plugin_opts)

      assert before.settings_cache ==
               :persistent_term.get(
                 {AllbertAssist.Settings.Fragments, :default_composition},
                 :not_cached
               )

      assert before.app_children ==
               DynamicSupervisor.which_children(AllbertAssist.App.DynamicSupervisor)

      assert before.plugin_children ==
               DynamicSupervisor.which_children(AllbertAssist.Plugin.ChildSupervisor)

      refute_receive {:signal, _signal}, 50
    end
  end

  defp closed_stub do
    %Closed{
      schema_version: 1,
      closed_applications: [],
      pack_applications: [],
      rows: [],
      projection_sha256: String.duplicate("0", 64),
      closure_sha256: String.duplicate("0", 64)
    }
  end

  defp closed_projection do
    kernel_sha256 = String.duplicate("a", 64)
    residual_sha256 = String.duplicate("b", 64)

    applications = [
      application(:allbert_kernel, Kernel, kernel_sha256),
      application(:allbert_assist, Residual, residual_sha256)
    ]

    source_rows = [
      source_row(
        "beam-allbert-kernel",
        "allbert_kernel",
        "allbert_kernel",
        Kernel,
        "kernel_prerequisite",
        0,
        kernel_sha256
      ),
      source_row(
        "beam-allbert-assist",
        "allbert_assist",
        "allbert_assist",
        Residual,
        "native_effectful",
        100,
        residual_sha256
      )
    ]

    release = %ReleaseSpec{
      name: "allbert",
      version: "1.3.2",
      erts_version: "16.1",
      applications:
        Enum.map(applications, fn application ->
          %ReleaseApplication{
            application: application.application,
            version: application.version,
            start_mode: :permanent,
            included_applications: []
          }
        end)
    }

    {:ok, closed} =
      Projection.reconcile_closed(source_rows, applications, release,
        sealed: true,
        closed_applications: Enum.map(applications, & &1.application),
        effective_env_fetcher: fn application, :allbert_pack ->
          case Enum.find(applications, &(&1.application == application)) do
            %ApplicationSpec{pack_module: module} -> {:ok, module}
          end
        end
      )

    closed
  end

  defp application(application, pack_module, sha256) do
    %ApplicationSpec{
      application: application,
      version: "1.3.2",
      modules: [pack_module],
      applications: [],
      pack_module: pack_module,
      sha256: sha256
    }
  end

  defp source_row(
         component,
         application,
         id,
         descriptor_module,
         startup_role,
         registry_order,
         app_sha256
       ) do
    %{
      "id" => component,
      "application" => application,
      "pack" => %{
        "schema_version" => 1,
        "id" => id,
        "descriptor_module" => Atom.to_string(descriptor_module),
        "startup_role" => startup_role,
        "registry_order" => registry_order,
        "app_sha256" => app_sha256
      }
    }
  end

  defp assert_unstable_capture(context) do
    assert {:error,
            {:capture_failed,
             [
               %ValidationDiagnostic{
                 schema_version: 1,
                 code: :invalid_value,
                 path: [],
                 owner: nil,
                 detail: %{reason: :unstable_registry_capture}
               }
             ]}} = LegacyAdapter.capture([{:pack_projection, closed_projection()} | context])
  end

  defp load_incomplete_behaviour_module!(module, behaviour, callbacks, missing_callback) do
    exports = List.delete(callbacks, missing_callback)

    functions =
      Enum.map(exports, fn {name, arity} ->
        arguments =
          if arity == 0 do
            []
          else
            Enum.map(1..arity, &{:var, 4, String.to_atom("Arg#{&1}")})
          end

        {:function, 4, name, arity,
         [{:clause, 4, arguments, [], [{:atom, 4, :unused_fixture_result}]}]}
      end)

    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 2, :behaviour, behaviour},
      {:attribute, 3, :export, exports}
      | functions
    ]

    binary =
      case :compile.forms(forms, [:binary, :return_errors, :return_warnings]) do
        {:ok, ^module, binary} ->
          binary

        {:ok, ^module, binary, _warnings} ->
          binary

        {:error, errors, warnings} ->
          flunk("fixture compile failed: #{inspect({errors, warnings})}")
      end

    assert {:module, ^module} = :code.load_binary(module, ~c"legacy_adapter_fixture", binary)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    module
  end

  defp moduleless_skill_entry(overrides \\ []) do
    overrides = Map.new(overrides)

    struct!(
      PluginEntry,
      Map.merge(
        %{
          plugin_id: "example.skills",
          display_name: "Example skills",
          version: "1.0.0",
          kind: "skills",
          source: :home,
          status: :enabled,
          trust_status: :pending,
          module: nil,
          root_path: declared_plugin_root("example.skills"),
          apps: [],
          channels: [],
          actions: [],
          skill_paths: [declared_skill_path("example.skills", "default")],
          settings_schema: [],
          release_availability: [],
          children: :ignore,
          diagnostics: []
        },
        overrides
      )
    )
  end

  defp declared_plugin_root(plugin_id) do
    Path.join([System.tmp_dir!(), "pack-adapter-fixtures", plugin_id])
  end

  defp declared_skill_path(plugin_id, name) do
    Path.join([declared_plugin_root(plugin_id), name, "skills"])
  end

  defp unsupported_json_values(value, path \\ [])

  defp unsupported_json_values(value, path) when is_map(value) do
    Enum.flat_map(value, fn
      {key, nested} when is_binary(key) -> unsupported_json_values(nested, [key | path])
      {key, nested} -> [{Enum.reverse([key | path]), nested}]
    end)
  end

  defp unsupported_json_values(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {nested, index} -> unsupported_json_values(nested, [index | path]) end)
  end

  defp unsupported_json_values(value, _path)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: []

  defp unsupported_json_values(value, path), do: [{Enum.reverse(path), value}]
end
