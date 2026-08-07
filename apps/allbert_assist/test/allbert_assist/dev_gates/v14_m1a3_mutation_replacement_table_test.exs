defmodule AllbertAssist.DevGates.V14M1A3MutationReplacementTableTest do
  use ExUnit.Case, async: true

  @fixture Path.expand("../../fixtures/v1.4/m1a3_mutation_replacement_table.json", __DIR__)
  @required_fields ~w[
    id owner surface visibility candidate_effect admission success_result validation_result
    unavailable_result committed_state replacement_failure cache_effect signal_effect child_effect
    focused_test
  ]

  @registry_sources [
    {AllbertAssist.App.Registry, "apps/allbert_assist/lib/allbert_assist/app/registry.ex"},
    {AllbertAssist.Plugin.Registry, "apps/allbert_assist/lib/allbert_assist/plugin/registry.ex"}
  ]

  test "the generated table classifies every mutation surface without a common outcome" do
    fixture = load_fixture!()
    rows = fixture["rows"]

    assert fixture["schema_version"] == 1
    assert fixture["normalization"] == "v14_m1a3_mutation_replacement_v1"
    assert is_list(rows) and rows != []
    assert Enum.uniq_by(rows, & &1["id"]) == rows

    Enum.each(rows, fn row ->
      assert Map.keys(row) |> Enum.sort() == Enum.sort(@required_fields)
      assert row["visibility"] in ["public_frozen", "internal_m1a3"]

      assert row["focused_test"] in [
               "AllbertAssist.App.RegistryTest",
               "AllbertAssist.Plugin.RegistryTest"
             ]
    end)

    classified_surfaces = MapSet.new(rows, &surface_tuple!/1)
    assert classified_surfaces == discover_production_mutation_surfaces()

    assert row!(rows, "app-register")["replacement_failure"] =~ "compensate"
    assert row!(rows, "app-unregister")["replacement_failure"] =~ "retain frozen :ok"
    assert row!(rows, "app-clear")["child_effect"] =~ "does not terminate"

    assert row!(rows, "plugin-register-module")["replacement_failure"] =~
             "preserve registered entry"
  end

  test "every classified surface is an exported facade and the table pins side effects" do
    rows = load_fixture!()["rows"]

    Enum.each(rows, fn row ->
      {module, function, arity} = surface_tuple!(row)
      assert function_exported?(module, function, arity), "missing #{row["surface"]}"
    end)

    effectful_rows =
      Enum.reject(rows, &String.starts_with?(&1["candidate_effect"], "candidate_neutral"))

    Enum.each(effectful_rows, fn row ->
      assert row["cache_effect"] != ""
      assert row["signal_effect"] != ""
      assert row["child_effect"] != ""
      assert row["replacement_failure"] != ""
    end)
  end

  test "source facades retain the frozen cache, signal, and child branches" do
    app_source = source!("apps/allbert_assist/lib/allbert_assist/app/registry.ex")
    plugin_source = source!("apps/allbert_assist/lib/allbert_assist/plugin/registry.ex")

    assert app_source =~ "clear_settings_schema_cache()"
    assert app_source =~ "emit_app_registered(module, app_id)"
    assert app_source =~ "emit_app_unregistered(app_id)"
    assert app_source =~ "emit_app_registry_cleared(count)"
    assert app_source =~ "terminate_child(entry, state)"

    assert plugin_source =~ "clear_settings_schema_cache()"
    assert plugin_source =~ "emit_plugin_registered(plugin_id, opts)"
    assert plugin_source =~ "emit_plugin_registry_cleared(count)"
    assert plugin_source =~ "mark_child_activation_state(state, plugin_id, result)"
  end

  defp load_fixture! do
    @fixture
    |> File.read!()
    |> Jason.decode!()
  end

  defp row!(rows, id), do: Enum.find(rows, &(&1["id"] == id)) || flunk("missing row #{id}")

  defp surface_tuple!(%{"owner" => owner, "surface" => surface}) do
    module = owner |> String.split(".") |> Enum.map(&String.to_existing_atom/1) |> Module.concat()
    [function, arity] = String.split(surface, "/", parts: 2)

    {module, String.to_existing_atom(function), String.to_integer(arity)}
  end

  defp discover_production_mutation_surfaces do
    @registry_sources
    |> Enum.flat_map(fn {module, path} ->
      path
      |> source!()
      |> Code.string_to_quoted!()
      |> public_genserver_facades(module)
    end)
    |> MapSet.new()
  end

  defp public_genserver_facades(ast, module) do
    {_ast, surfaces} =
      Macro.prewalk(ast, [], fn
        {:def, _meta, [head, body]} = node, acc ->
          {name, arity} = function_name_arity!(head)

          if direct_genserver_mutation?(body) do
            {node, [{module, name, arity} | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    surfaces
  end

  defp function_name_arity!({:when, _meta, [head | _guards]}),
    do: function_name_arity!(head)

  defp function_name_arity!({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp direct_genserver_mutation?(body) do
    {_body, found?} =
      Macro.prewalk(body, false, fn
        {{:., _dot_meta, [{:__aliases__, _alias_meta, [:GenServer]}, function]}, _call_meta,
         _args} = node,
        _found?
        when function in [:call, :cast] ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp source!(relative_path), do: File.read!(Path.join(project_root(), relative_path))
  defp project_root, do: Path.expand("../../../../..", __DIR__)
end
