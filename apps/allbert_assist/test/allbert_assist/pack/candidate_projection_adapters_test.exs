defmodule AllbertAssist.Pack.CandidateProjectionAdaptersTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.Extensions.Registry, as: ExtensionsRegistry
  alias AllbertAssist.Pack.ActionProjection
  alias AllbertAssist.Settings.Fragments

  test "candidate settings fragments use supplied entry order after core fragments" do
    assert {:ok, fragments} =
             Fragments.candidate_fragments(
               [
                 %{
                   app_id: :candidate_settings,
                   display_name: "Candidate Settings",
                   settings_schema: [
                     %{key: "apps.candidate_settings.enabled", type: :boolean, default: true}
                   ]
                 }
               ],
               [
                 %{
                   plugin_id: "candidate.settings",
                   display_name: "Candidate Plugin Settings",
                   source: :project,
                   trust_status: :trusted,
                   settings_schema: [
                     %{key: "candidate.settings.enabled", type: :boolean, default: false}
                   ]
                 }
               ]
             )

    assert Enum.at(fragments, -2).id == "app:candidate_settings"
    assert List.last(fragments).id == "plugin:candidate.settings"

    assert {:error, [%{detail: %{reason: :invalid_app_entry}}]} =
             Fragments.candidate_fragments([%{app_id: :broken, settings_schema: :not_a_list}], [])
  end

  test "candidate settings fragments reject malformed App schema rows" do
    assert {:error, [%{detail: %{reason: {:invalid_app_settings_schema_entry, 1}}}]} =
             Fragments.candidate_fragments(
               [
                 %{
                   app_id: :broken,
                   settings_schema: [
                     %{key: "apps.broken.enabled", type: "boolean", default: true}
                   ]
                 }
               ],
               []
             )
  end

  test "candidate settings fragments reject duplicate Plugin schema keys" do
    row = %{key: "candidate.settings.enabled", type: :boolean, default: true}

    assert {:error,
            [
              %{
                detail: %{
                  reason: {:duplicate_plugin_settings_schema_key, "candidate.settings.enabled"}
                }
              }
            ]} =
             Fragments.candidate_fragments(
               [],
               [
                 %{
                   plugin_id: "candidate.settings",
                   display_name: "Candidate Plugin Settings",
                   source: :project,
                   trust_status: :trusted,
                   settings_schema: [row, row]
                 }
               ]
             )
  end

  test "candidate intent descriptors use the supplied action projection instead of live registries" do
    app_entries = [
      %{
        app_id: :stocksage,
        module: StockSage.App,
        actions: StockSage.App.actions()
      }
    ]

    plugin_entries = [
      %{
        plugin_id: "stocksage",
        status: :enabled,
        apps: [StockSage.App],
        actions: StockSage.App.actions()
      }
    ]

    assert {:ok, descriptors} =
             ExtensionsRegistry.intent_descriptors_from_entries(app_entries, plugin_entries)

    assert [%{app_id: :stocksage, action_name: "run_analysis"} | _] = descriptors

    assert {:error, [%{detail: %{reason: :dangling_app_action_membership}}]} =
             ActionProjection.metadata(app_entries, [])
  end

  # The projection used to index effective plugin actions by their POSITION in
  # the entry list, which quietly made plugin registration order part of the
  # contract. It held only because the shipped registration order happens to be
  # ascending above the residual boundary. A pack registering from its own
  # application lands elsewhere in that list, and the 1..N assertion then failed
  # with :invalid_registry_order -- which is what reverted the first notes_files
  # extraction, and what telegram and email would have hit at M12.
  #
  # Ordering is now taken from the declared registry_order. This pins both halves:
  # entry order must not matter, and the tokens must still form an exact
  # contiguous sequence, so the fix cannot be mistaken for a relaxation.
  describe "effective plugin ordering" do
    setup do
      plugin_entries =
        AllbertAssist.Plugin.Registry.registered_plugins()
        |> Enum.map(&%{plugin_id: &1.plugin_id, actions: &1.actions, status: &1.status})

      app_entries =
        AllbertAssist.App.Registry.registered_apps()
        |> Enum.map(&%{app_id: &1.app_id, actions: Map.get(&1, :actions, [])})

      {:ok, static} = ActionProjection.static()
      %{static: static, app_entries: app_entries, plugin_entries: plugin_entries}
    end

    test "is independent of the order plugins registered in", ctx do
      assert {:ok, _} = ActionProjection.build(ctx.static, ctx.app_entries, ctx.plugin_entries)

      assert {:ok, _} =
               ActionProjection.build(
                 ctx.static,
                 ctx.app_entries,
                 Enum.reverse(ctx.plugin_entries)
               )

      # The extraction scenario: a pack registering last rather than in place.
      {extracted, rest} =
        Enum.split_with(ctx.plugin_entries, &(&1.plugin_id == "allbert.notes_files"))

      assert extracted != [], "expected allbert.notes_files in the live plugin registry"
      assert {:ok, _} = ActionProjection.build(ctx.static, ctx.app_entries, rest ++ extracted)
    end

    test "still rejects a sequence that is not exactly 1..N", ctx do
      hole = Enum.reject(ctx.plugin_entries, &(&1.plugin_id == "allbert.discord"))

      assert {:error, [%{detail: %{reason: :invalid_registry_order}} | _]} =
               ActionProjection.build(ctx.static, ctx.app_entries, hole)

      duplicated =
        Enum.map(ctx.plugin_entries, fn entry ->
          if entry.plugin_id == "allbert.slack",
            do: %{entry | actions: entry.actions ++ entry.actions},
            else: entry
        end)

      assert {:error, [%{detail: %{reason: :invalid_registry_order}} | _]} =
               ActionProjection.build(ctx.static, ctx.app_entries, duplicated)
    end
  end
end
