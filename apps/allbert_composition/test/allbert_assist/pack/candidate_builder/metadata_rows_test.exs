defmodule AllbertAssist.Pack.CandidateBuilder.MetadataRowsTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.App.Registry.MetadataEntry, as: AppEntry
  alias AllbertAssist.App.Registry.MetadataSnapshot, as: AppSnapshot
  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Pack.CandidateBuilder.MetadataRows
  alias AllbertAssist.Pack.Projection.Closed
  alias AllbertAssist.Plugin.Registry.MetadataEntry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry.MetadataSnapshot, as: PluginSnapshot
  alias AllbertAssist.Settings.Fragment
  alias AllbertAssist.Surface

  defmodule AppOne do
  end

  defmodule AppTwo do
  end

  defmodule PluginOne do
  end

  test "app membership mutation changes the owning app row" do
    app = app_entry()

    assert {:ok, residual} = build([app], [])
    assert Map.has_key?(residual.apps, "allbert_assist")

    assert {:ok, plugin_owned} = build([app], [plugin_entry(apps: [AppOne])])
    assert Map.has_key?(plugin_owned.apps, "plugin-one")
    refute Map.has_key?(plugin_owned.apps, "allbert_assist")
  end

  test "every inert App descriptor input class changes its canonical row" do
    app = app_entry()

    mutations = [
      app_id: :changed_demo,
      module: AppTwo,
      display_name: "Changed demo",
      version: "2",
      agents: [AppTwo],
      signals: %{emits: [:changed], subscribes: [:changed]},
      memory_namespace: %{
        app_id: :demo,
        namespace: "changed",
        writable: true,
        description: "Changed memory"
      },
      surface_provider: AppTwo,
      surface_catalog: [%{component: :card, allowed_props: [:title], allowed_bindings: []}],
      child_id: {:changed, :demo},
      metadata: %{changed: true}
    ]

    assert {:ok, baseline} = build([app], [])

    Enum.each(mutations, fn {field, value} ->
      assert {:ok, changed} = build([struct!(app, %{field => value})], [])

      refute app_row_identity(baseline) == app_row_identity(changed),
             "expected #{field} to participate in the App descriptor"
    end)

    assert {:error, _diagnostics} = build([struct!(app, surfaces: [%{}])], [])
  end

  test "settings fragment mutation changes its schema-owned projection digest" do
    first = fragment(%{"demo.flag" => schema_entry(false)})
    second = fragment(%{"demo.flag" => schema_entry(true)})

    assert {:ok, first_rows} = build([], [], settings_fragments: [first])
    assert {:ok, second_rows} = build([], [], settings_fragments: [second])

    [first_row] = first_rows.settings_fragments["allbert_assist"]
    [second_row] = second_rows.settings_fragments["allbert_assist"]
    refute first_row.payload["projection_sha256"] == second_row.payload["projection_sha256"]
  end

  test "provider surface mutation changes the surface row projection digest" do
    first = app_entry(provider_surfaces: [surface("Overview")])
    second = app_entry(provider_surfaces: [surface("Changed overview")])

    assert {:ok, first_rows} = build([first], [])
    assert {:ok, second_rows} = build([second], [])

    [first_row] = first_rows.surfaces["allbert_assist"]
    [second_row] = second_rows.surfaces["allbert_assist"]
    refute first_row.payload["projection_sha256"] == second_row.payload["projection_sha256"]
  end

  test "intent mutation changes the intent row projection digest" do
    app = app_entry()

    assert {:ok, first_rows} = build([app], [], intent_descriptors: [intent("Open demo")])
    assert {:ok, second_rows} = build([app], [], intent_descriptors: [intent("Changed demo")])

    [first_row] = first_rows.intent_descriptors["allbert_assist"]
    [second_row] = second_rows.intent_descriptors["allbert_assist"]
    refute first_row.payload["projection_sha256"] == second_row.payload["projection_sha256"]
  end

  test "declared plugin skill root mutation changes the root identity" do
    first =
      plugin_entry(
        module: nil,
        root_path: "/tmp/plugin-one",
        skill_paths: ["/tmp/plugin-one/skills"]
      )

    second =
      plugin_entry(
        module: nil,
        root_path: "/tmp/plugin-one",
        skill_paths: ["/tmp/plugin-one/other-skills"]
      )

    assert {:ok, first_rows} = build([], [first])
    assert {:ok, second_rows} = build([], [second])

    [first_row] = first_rows.skill_roots["plugin-one"]
    [second_row] = second_rows.skill_roots["plugin-one"]
    refute first_row.identity.value == second_row.identity.value
  end

  defp build(apps, plugins, opts \\ []) do
    opts =
      Keyword.merge([settings_fragments: [], intent_descriptors: [], action_bindings: []], opts)

    MetadataRows.build(
      closed(),
      %AppSnapshot{schema_version: 1, generation: 0, entries: apps},
      %PluginSnapshot{schema_version: 1, generation: 0, entries: plugins},
      opts
    )
  end

  defp app_entry(overrides \\ []) do
    attrs =
      [
        app_id: :demo,
        module: AppOne,
        display_name: "Demo",
        version: "1",
        agents: [],
        actions: [],
        signals: %{emits: [], subscribes: []},
        skill_paths: [],
        settings_schema: [],
        memory_namespace: nil,
        surfaces: [],
        surface_provider: nil,
        provider_surfaces: [],
        surface_catalog: [],
        child_id: :demo,
        metadata: %{}
      ]
      |> Keyword.merge(overrides)

    struct!(AppEntry, attrs)
  end

  defp plugin_entry(overrides) do
    attrs =
      [
        plugin_id: "plugin-one",
        display_name: "Plugin One",
        source: :local,
        status: :enabled,
        trust_status: :trusted,
        module: PluginOne,
        apps: [],
        channels: [],
        actions: [],
        root_path: nil,
        skill_paths: [],
        settings_schema: [],
        children: :ignore
      ]
      |> Keyword.merge(overrides)

    struct!(PluginEntry, attrs)
  end

  defp fragment(schema) do
    Fragment.new!(%{
      id: "core:demo",
      owner: :demo,
      source: :core,
      group: "demo",
      schema: schema,
      defaults: %{},
      safe_write_keys: [],
      metadata: %{}
    })
  end

  defp schema_entry(default),
    do: %{type: :boolean, default: default, writable?: true, sensitive?: false}

  defp surface(label) do
    %Surface{
      id: "demo-surface",
      app_id: :demo,
      label: label,
      path: "/demo",
      kind: :workspace,
      zone: :canvas,
      status: :available
    }
  end

  defp intent(label) do
    %Descriptor{
      id: "demo:open_demo",
      app_id: :demo,
      action_name: "open_demo",
      label: label,
      source: :app,
      source_module: AppOne,
      capability: %{
        name: "open_demo",
        module: AppOne,
        registered?: false,
        permission: :read_only,
        exposure: :agent,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required,
        resumable?: false,
        retry_safety: :safe,
        app_id: :demo,
        plugin_id: nil
      }
    }
  end

  defp app_row_identity(rows) do
    rows.apps
    |> Map.fetch!("allbert_assist")
    |> List.first()
    |> Map.fetch!(:payload)
    |> Map.fetch!("contract_sha256")
  end

  defp closed do
    %Closed{
      schema_version: 1,
      closed_applications: [],
      pack_applications: [],
      rows: [],
      projection_sha256: String.duplicate("0", 64),
      closure_sha256: String.duplicate("0", 64)
    }
  end
end
