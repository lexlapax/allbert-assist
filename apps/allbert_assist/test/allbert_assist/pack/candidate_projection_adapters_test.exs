defmodule AllbertAssist.Pack.CandidateProjectionAdaptersTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Extensions.Registry, as: ExtensionsRegistry
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

    assert {:ok, static} = ActionsRegistry.static_projection()

    assert {:error, [%{detail: %{reason: :dangling_app_action_membership}}]} =
             ActionsRegistry.candidate_projection(static, app_entries, [])
  end
end
