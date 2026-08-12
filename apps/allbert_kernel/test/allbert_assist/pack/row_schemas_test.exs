defmodule AllbertAssist.Pack.RowSchemasTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Pack.{
    Compatibility,
    Contribution,
    Descriptor,
    Order,
    Owner,
    Row,
    RowSchemas
  }

  alias AllbertAssist.Pack.RowSchemas.Input

  @callbacks [
    :apps,
    :actions,
    :settings_fragments,
    :settings_migrations,
    :channels,
    :surfaces,
    :skill_roots,
    :home_roots,
    :jobs,
    :stores,
    :prompt_rules,
    :intent_descriptors,
    :cli_groups,
    :release_assets,
    :test_lanes
  ]

  @schema_cases [
    {:app_descriptor_v1, "module"},
    {:action_ref_v1, "name"},
    {:settings_fragment_ref_v1, "schema_version"},
    {:channel_descriptor_v1, "module"},
    {:surface_ref_v1, "surface_id"},
    {:skill_root_v1, "trust_policy"},
    {:home_root_v1, "backup"},
    {:job_ref_v1, "module"},
    {:store_ref_v1, "module"},
    {:prompt_rule_ref_v1, "rule_id"},
    {:intent_descriptor_ref_v1, "module"},
    {:cli_group_ref_v1, "group_id"},
    {:release_asset_v1, "kind"},
    {:test_lane_v1, "aggregate_policy"}
  ]

  @nonempty_authority_cases [
    {:app_descriptor_v1, "app_id"},
    {:action_ref_v1, "kind"},
    {:settings_fragment_ref_v1, "schema_version"},
    {:channel_descriptor_v1, "adapter"},
    {:surface_ref_v1, "id"},
    {:intent_descriptor_ref_v1, "selection_policy"}
  ]

  test "normalizes typed Input into separate payload and source-authority projections" do
    {input, expected_payload, expected_authority} = valid_fixture(:app_descriptor_v1)

    input = %{
      input
      | payload: %{
          module: AllbertAssist,
          app_id: :allbert,
          contract_sha256: input.payload["contract_sha256"]
        }
    }

    normalized = RowSchemas.normalize!(:app_descriptor_v1, input)

    assert RowSchemas.canonical_projection(normalized) == expected_payload
    assert RowSchemas.source_authority_projection(normalized) == expected_authority
  end

  test "the executable contract is canonical JSON in frozen callback order" do
    first = RowSchemas.schema_contract()
    assert first == RowSchemas.schema_contract()
    assert RowSchemas.callback_order() == @callbacks
    assert Enum.map(first, & &1["callback"]) == Enum.map(@callbacks, &Atom.to_string/1)

    assert Enum.map(first, & &1["payload_schema"]) ==
             Enum.map(@callbacks, &Atom.to_string(RowSchemas.payload_schema_for!(&1)))

    assert Enum.all?(first, &canonical_json?/1)

    migration = contract(first, :settings_migration_ref_v1)
    assert migration["reserved_empty"]
    assert migration["fields"] == []
    assert migration["source_authority"]["kind"] == "none"

    assert field_contract(first, :settings_fragment_ref_v1, "owner_id")[
             "owner_reference_source"
           ] == "owner.id"

    assert field_contract(first, :release_asset_v1, "component")[
             "owner_reference_source"
           ] == "descriptor.provenance.component"

    assert authority_field_contract(first, :settings_fragment_ref_v1, "legacy_owner_id")[
             "owner_reference"
           ] == "none"

    skill_root_ref =
      contract(first, :app_descriptor_v1)["source_authority"]["definitions"][
        "skill_root_ref_authority_v1"
      ]

    assert Enum.find(skill_root_ref["fields"], &(&1["name"] == "owner_id"))[
             "owner_reference_source"
           ] == "owner.id"

    assert authority_field_contract(first, :channel_descriptor_v1, "primitives")[
             "list_semantics"
           ] == "ordered"

    assert authority_field_contract(first, :settings_fragment_ref_v1, "safe_write_keys")[
             "list_semantics"
           ] == "ordered"

    assert_raise ArgumentError, fn -> RowSchemas.payload_schema_for!(:unknown_callback) end
  end

  for {schema, scalar_field} <- @schema_cases do
    test "#{schema} closes payload keys/types and rejects unclassified lists" do
      schema = unquote(schema)
      scalar_field = unquote(scalar_field)
      {input, expected_payload, expected_authority} = valid_fixture(schema)

      normalized = RowSchemas.normalize!(schema, input)
      assert RowSchemas.canonical_projection(normalized) == expected_payload
      assert RowSchemas.source_authority_projection(normalized) == expected_authority

      assert_raise ArgumentError, fn ->
        input
        |> update_payload(&Map.delete(&1, scalar_field))
        |> then(&RowSchemas.normalize!(schema, &1))
      end

      assert_raise ArgumentError, fn ->
        input
        |> update_payload(&Map.put(&1, "unexpected", "value"))
        |> then(&RowSchemas.normalize!(schema, &1))
      end

      assert_raise ArgumentError, fn ->
        input
        |> update_payload(&Map.put(&1, scalar_field, 1.5))
        |> then(&RowSchemas.normalize!(schema, &1))
      end

      assert_raise ArgumentError, fn ->
        input
        |> update_payload(&Map.put(&1, scalar_field, [input.payload[scalar_field]]))
        |> then(&RowSchemas.normalize!(schema, &1))
      end
    end
  end

  for {schema, scalar_field} <- @nonempty_authority_cases do
    test "#{schema} source authority is exact, typed, and list-classified" do
      schema = unquote(schema)
      scalar_field = unquote(scalar_field)
      {input, _payload, expected_authority} = valid_fixture(schema)

      normalized = RowSchemas.normalize!(schema, input)
      assert RowSchemas.source_authority_projection(normalized) == expected_authority

      assert_raise ArgumentError, fn ->
        input
        |> update_authority(&Map.delete(&1, scalar_field))
        |> then(&RowSchemas.reference_digest_for!(schema, &1))
      end

      assert_raise ArgumentError, fn ->
        input
        |> update_authority(&Map.put(&1, "unexpected", "value"))
        |> then(&RowSchemas.reference_digest_for!(schema, &1))
      end

      assert_raise ArgumentError, fn ->
        input
        |> update_authority(&Map.put(&1, scalar_field, 1.5))
        |> then(&RowSchemas.reference_digest_for!(schema, &1))
      end

      assert_raise ArgumentError, fn ->
        input
        |> update_authority(&Map.put(&1, scalar_field, [input.source_authority[scalar_field]]))
        |> then(&RowSchemas.reference_digest_for!(schema, &1))
      end
    end
  end

  test "reserved, empty-authority, and no-authority schemas are closed" do
    assert_raise ArgumentError, fn ->
      RowSchemas.normalize!(
        :settings_migration_ref_v1,
        %Input{payload: %{}, source_authority: nil}
      )
    end

    {skill, _payload, _authority} = valid_fixture(:skill_root_v1)

    assert_raise ArgumentError, fn ->
      RowSchemas.reference_digest_for!(:skill_root_v1, %{skill | source_authority: nil})
    end

    assert_raise ArgumentError, fn ->
      RowSchemas.reference_digest_for!(:skill_root_v1, %{
        skill
        | source_authority: %{"unexpected" => true}
      })
    end

    {asset, _payload, _authority} = valid_fixture(:release_asset_v1)

    assert RowSchemas.reference_digest_for!(:release_asset_v1, asset) == nil

    assert_raise ArgumentError, fn ->
      RowSchemas.reference_digest_for!(:release_asset_v1, %{asset | source_authority: %{}})
    end
  end

  test "normalization and projection APIs require authentic typed boundaries" do
    {input, _payload, _authority} = valid_fixture(:app_descriptor_v1)

    Code.ensure_loaded!(RowSchemas)
    Code.ensure_loaded!(RowSchemas.Normalized)
    refute function_exported?(RowSchemas.Normalized, :normalize!, 2)
    refute function_exported?(RowSchemas.Normalized, :projections, 1)
    refute function_exported?(RowSchemas, :normalized_components!, 2)

    assert_raise ArgumentError, fn ->
      RowSchemas.normalize!(:app_descriptor_v1, input.payload)
    end

    assert_raise ArgumentError, fn -> RowSchemas.canonical_projection(%{}) end
    assert_raise ArgumentError, fn -> RowSchemas.source_authority_projection(%{}) end

    forged = %RowSchemas.Normalized{
      schema: :app_descriptor_v1,
      payload: %{},
      source_authority: %{},
      validation_token: :forged
    }

    assert_raise ArgumentError, fn -> RowSchemas.canonical_projection(forged) end
    assert_raise ArgumentError, fn -> RowSchemas.source_authority_projection(forged) end

    invalid = update_payload(input, &Map.put(&1, "contract_sha256", String.duplicate("0", 64)))
    assert_raise ArgumentError, fn -> RowSchemas.normalize!(:app_descriptor_v1, invalid) end
  end

  test "reference digest binds payload and lossless source authority without trusting stored bytes" do
    {input, expected_payload, expected_authority} = valid_fixture(:app_descriptor_v1)
    expected = expected_payload["contract_sha256"]

    assert RowSchemas.reference_digest_for!(:app_descriptor_v1, input) == expected

    independently_computed =
      row_digest(
        :app_descriptor_v1,
        Map.delete(expected_payload, "contract_sha256"),
        expected_authority
      )

    assert expected == independently_computed

    wrong_stored =
      update_payload(input, &Map.put(&1, "contract_sha256", String.duplicate("0", 64)))

    assert RowSchemas.reference_digest_for!(:app_descriptor_v1, wrong_stored) == expected
    assert_raise ArgumentError, fn -> RowSchemas.normalize!(:app_descriptor_v1, wrong_stored) end
  end

  test "legacy authority list order changes the digest instead of being normalized away" do
    {app, _payload, _authority} = valid_fixture(:app_descriptor_v1)

    # Build the nested updates explicitly so every tested list remains ordered authority.
    [catalog | rest] = app.source_authority["surface_catalog"]

    reordered_catalog = [
      %{catalog | "allowed_props" => Enum.reverse(catalog["allowed_props"])} | rest
    ]

    app_reordered = %{
      app
      | source_authority: %{app.source_authority | "surface_catalog" => reordered_catalog}
    }

    reordered_bindings = [
      %{catalog | "allowed_bindings" => Enum.reverse(catalog["allowed_bindings"])} | rest
    ]

    app_bindings_reordered = %{
      app
      | source_authority: %{app.source_authority | "surface_catalog" => reordered_bindings}
    }

    {channel, _payload, _authority} = valid_fixture(:channel_descriptor_v1)

    channel_reordered =
      update_authority(
        channel,
        &Map.update!(&1, "primitives", fn values -> Enum.reverse(values) end)
      )

    {settings, _payload, _authority} = valid_fixture(:settings_fragment_ref_v1)

    settings_reordered =
      update_authority(
        settings,
        &Map.update!(&1, "safe_write_keys", fn values -> Enum.reverse(values) end)
      )

    refute RowSchemas.reference_digest_for!(:app_descriptor_v1, app) ==
             RowSchemas.reference_digest_for!(:app_descriptor_v1, app_reordered)

    refute RowSchemas.reference_digest_for!(:app_descriptor_v1, app) ==
             RowSchemas.reference_digest_for!(:app_descriptor_v1, app_bindings_reordered)

    refute RowSchemas.reference_digest_for!(:channel_descriptor_v1, channel) ==
             RowSchemas.reference_digest_for!(:channel_descriptor_v1, channel_reordered)

    refute RowSchemas.reference_digest_for!(:settings_fragment_ref_v1, settings) ==
             RowSchemas.reference_digest_for!(:settings_fragment_ref_v1, settings_reordered)
  end

  test "descriptor child authority rejects arbitrary terms and unsafe options" do
    {input, _payload, _authority} = valid_fixture(:channel_descriptor_v1)

    assert_raise ArgumentError, fn ->
      input
      |> update_authority(&Map.put(&1, "child_spec", {:raw, self()}))
      |> then(&RowSchemas.reference_digest_for!(:channel_descriptor_v1, &1))
    end

    assert_raise ArgumentError, fn ->
      input
      |> update_authority(fn authority ->
        put_in(authority["child_spec"]["options"], [self()])
      end)
      |> then(&RowSchemas.reference_digest_for!(:channel_descriptor_v1, &1))
    end
  end

  test "safe authority grammar rejects structs, functions, absolute roots, and unsafe surface data" do
    {app, _payload, _authority} = valid_fixture(:app_descriptor_v1)

    for unsafe <- [self(), fn -> :unsafe end, ~r/unsafe/] do
      assert_raise ArgumentError, fn ->
        app
        |> update_authority(&Map.put(&1, "metadata", %{"unsafe" => unsafe}))
        |> then(&RowSchemas.reference_digest_for!(:app_descriptor_v1, &1))
      end
    end

    assert_raise ArgumentError, fn ->
      app
      |> update_authority(&Map.put(&1, "metadata", %{"path" => "/Users/private"}))
      |> then(&RowSchemas.reference_digest_for!(:app_descriptor_v1, &1))
    end

    {surface, _payload, _authority} = valid_fixture(:surface_ref_v1)

    assert_raise ArgumentError, fn ->
      surface
      |> update_authority(&Map.put(&1, "metadata", %{"remote" => "https://example.test"}))
      |> then(&RowSchemas.reference_digest_for!(:surface_ref_v1, &1))
    end
  end

  test "validated service prefixes and local Surface routes are not mistaken for filesystem roots" do
    {settings, _payload, _authority} = valid_fixture(:settings_fragment_ref_v1)

    settings =
      update_authority(settings, fn authority ->
        Map.put(authority, "defaults", %{
          "public_api" => %{"path_prefix" => "/", "version_prefix" => "/v1"}
        })
      end)

    assert is_binary(RowSchemas.reference_digest_for!(:settings_fragment_ref_v1, settings))

    {surface, _payload, _authority} = valid_fixture(:surface_ref_v1)

    surface =
      update_authority(surface, fn authority ->
        update_in(authority["nodes"], fn [node | rest] ->
          [
            %{
              node
              | "props" => %{
                  "href" => "/jobs",
                  "route" => "/workspace?destination=workspace:discover"
                }
            }
            | rest
          ]
        end)
      end)

    assert is_binary(RowSchemas.reference_digest_for!(:surface_ref_v1, surface))
  end

  test "payload path and list normalization remains deterministic" do
    {skill, _payload, _authority} = valid_fixture(:skill_root_v1)

    for path <- ["/absolute", "../escape", "safe/../escape", "safe\\escape", "safe//escape"] do
      assert_raise ArgumentError, fn ->
        skill
        |> update_payload(&Map.put(&1, "relative_path", path))
        |> then(&RowSchemas.reference_digest_for!(:skill_root_v1, &1))
      end
    end

    {lane, expected, _authority} = valid_fixture(:test_lane_v1)
    normalized = RowSchemas.normalize!(:test_lane_v1, lane)
    assert RowSchemas.canonical_projection(normalized) == expected
    assert expected["production_roots"] == ["apps/alpha", "apps/zeta"]
    assert expected["allowed_primary_lanes"] == ["core", "web"]
  end

  test "alias authority validates Contribution context and owner-neutralizes all classified sources" do
    contribution = contribution()

    for schema <- [
          :app_descriptor_v1,
          :settings_fragment_ref_v1,
          :release_asset_v1,
          :test_lane_v1
        ] do
      {input, payload, _authority} = valid_fixture(schema)
      row = row(schema, input, payload)
      projection = RowSchemas.alias_authority_projection!(row, contribution)

      assert projection["kind"] == Atom.to_string(row.kind)
      assert projection["payload_schema"] == Atom.to_string(schema)

      assert projection["identity"]["value"] == row.identity.value
      assert projection["order_value"] == row.order.value

      for field <- owner_fields(schema) do
        assert projection["authority"][field] == "<ALIAS_OWNER>"
      end
    end
  end

  test "owner-only changes preserve alias authority including digest-bound settings authority" do
    original_contribution = contribution()

    renamed_owner = %Owner{
      schema_version: 1,
      kind: :declared_pack,
      id: "renamed_pack",
      application: :renamed_app
    }

    renamed_contribution = contribution(renamed_owner, "beam-renamed-pack")

    for schema <- [
          :app_descriptor_v1,
          :settings_fragment_ref_v1,
          :release_asset_v1,
          :test_lane_v1
        ] do
      {original_input, original_payload, _authority} = valid_fixture(schema)
      renamed_input = input_for_contribution(schema, original_input, renamed_contribution)
      renamed_payload = normalized_payload(schema, renamed_input)

      original_projection =
        schema
        |> row(original_input, original_payload)
        |> RowSchemas.alias_authority_projection!(original_contribution)

      renamed_projection =
        schema
        |> row(renamed_input, renamed_payload)
        |> then(&%{&1 | owner_id: renamed_owner.id})
        |> RowSchemas.alias_authority_projection!(renamed_contribution)

      assert original_projection == renamed_projection
    end
  end

  test "alias authority rejects owner/application/provenance and Row semantic mismatches" do
    contribution = contribution()
    {lane_input, lane_payload, _authority} = valid_fixture(:test_lane_v1)
    lane = row(:test_lane_v1, lane_input, lane_payload)

    assert_raise ArgumentError, fn ->
      RowSchemas.alias_authority_projection!(%{lane | owner_id: "other"}, contribution)
    end

    assert_raise ArgumentError, fn ->
      RowSchemas.alias_authority_projection!(
        %{lane | identity: %{lane.identity | value: "other"}},
        contribution
      )
    end

    assert_raise ArgumentError, fn ->
      RowSchemas.alias_authority_projection!(
        lane,
        %{contribution | owner: %{contribution.owner | application: nil}}
      )
    end

    {asset_input, asset_payload, _authority} = valid_fixture(:release_asset_v1)
    asset = row(:release_asset_v1, asset_input, asset_payload)

    assert_raise ArgumentError, fn ->
      RowSchemas.alias_authority_projection!(asset, %{contribution | descriptor: nil})
    end

    mismatched = put_in(contribution.descriptor.provenance.component, "beam-other")

    assert_raise ArgumentError, fn ->
      RowSchemas.alias_authority_projection!(asset, mismatched)
    end

    {app_input, _app_payload, _authority} = valid_fixture(:app_descriptor_v1)

    app_input =
      app_input
      |> update_authority(fn authority ->
        Map.update!(authority, "skill_root_refs", fn refs ->
          Enum.map(refs, &Map.put(&1, "owner_id", "other_owner"))
        end)
      end)
      |> with_recomputed_digest(:app_descriptor_v1)

    app = row(:app_descriptor_v1, app_input, normalized_payload(:app_descriptor_v1, app_input))

    assert_raise ArgumentError, fn ->
      RowSchemas.alias_authority_projection!(app, contribution)
    end
  end

  test "action alias-target order is admitted only for action rows" do
    contribution = contribution()
    {action_input, action_payload, _authority} = valid_fixture(:action_ref_v1)
    action = row(:action_ref_v1, action_input, action_payload)

    assert RowSchemas.alias_authority_projection!(
             %{action | order: %{namespace: :alias_target, value: 7}},
             contribution
           )["order_value"] == 7

    {channel_input, channel_payload, _authority} = valid_fixture(:channel_descriptor_v1)
    channel = row(:channel_descriptor_v1, channel_input, channel_payload)

    assert_raise ArgumentError, fn ->
      RowSchemas.alias_authority_projection!(
        %{channel | order: %{namespace: :alias_target, value: 7}},
        contribution
      )
    end
  end

  defp valid_fixture(schema) do
    normalized_payload = payload_without_digest(schema)
    source_authority = source_authority(schema)
    digest_field = reference_digest_field(schema)

    expected_payload =
      if digest_field do
        Map.put(
          normalized_payload,
          digest_field,
          row_digest(schema, normalized_payload, source_authority)
        )
      else
        normalized_payload
      end

    raw_payload =
      if schema == :test_lane_v1 do
        %{
          expected_payload
          | "production_roots" => ["apps/zeta", "apps/alpha", "apps/alpha"],
            "test_roots" => ["test/zeta", "test/alpha"],
            "support_roots" => ["test/support/z", "test/support/a"],
            "allowed_primary_lanes" => ["web", "core", "web"],
            "historical_metrics_aliases" => ["core", "allbert"]
        }
      else
        expected_payload
      end

    {%Input{payload: raw_payload, source_authority: source_authority}, expected_payload,
     source_authority}
  end

  defp payload_without_digest(:app_descriptor_v1),
    do: %{"module" => "AllbertAssist", "app_id" => "allbert"}

  defp payload_without_digest(:action_ref_v1),
    do: %{
      "module" => "AllbertAssist.Actions.Run",
      "name" => "run",
      "registry_order" => nil
    }

  defp payload_without_digest(:settings_fragment_ref_v1),
    do: %{"fragment_id" => "core", "owner_id" => "allbert_assist", "schema_version" => 1}

  defp payload_without_digest(:channel_descriptor_v1),
    do: %{"channel_id" => "tui", "module" => "AllbertAssist.Channels.TUI"}

  defp payload_without_digest(:surface_ref_v1),
    do: %{"surface_id" => "workspace", "module" => nil}

  defp payload_without_digest(:skill_root_v1),
    do: %{
      "root_id" => "builtin",
      "relative_path" => "priv/skills/builtin",
      "trust_policy" => "trusted"
    }

  defp payload_without_digest(:home_root_v1),
    do: %{
      "root_id" => "memory",
      "relative_path" => "memory",
      "durability" => "durable",
      "backup" => "include",
      "export" => "include",
      "rebuild" => "none"
    }

  defp payload_without_digest(:job_ref_v1),
    do: %{"job_id" => "compact_memory", "module" => "AllbertAssist.Jobs.CompactMemory"}

  defp payload_without_digest(:store_ref_v1),
    do: %{"store_id" => "memory", "module" => "AllbertAssist.Stores.Memory"}

  defp payload_without_digest(:prompt_rule_ref_v1),
    do: %{"rule_id" => "core", "module" => nil}

  defp payload_without_digest(:intent_descriptor_ref_v1),
    do: %{"intent_id" => "memory.search", "module" => "AllbertAssist.Intents.MemorySearch"}

  defp payload_without_digest(:cli_group_ref_v1),
    do: %{
      "group_id" => "pack",
      "command_path" => ["allbert", "pack", "inspect"],
      "module" => "AllbertAssist.CLI.Pack"
    }

  defp payload_without_digest(:release_asset_v1),
    do: %{
      "asset_id" => "daemon",
      "relative_path" => "bin/allbert-daemon",
      "kind" => "binary",
      "component" => "beam-allbert-assist",
      "source_sha256" => nil
    }

  defp payload_without_digest(:test_lane_v1),
    do: %{
      "owner_id" => "allbert_assist",
      "application" => "allbert_assist",
      "cwd" => "apps/allbert_assist",
      "production_roots" => ["apps/alpha", "apps/zeta"],
      "test_roots" => ["test/alpha", "test/zeta"],
      "support_roots" => ["test/support/a", "test/support/z"],
      "allowed_primary_lanes" => ["core", "web"],
      "aggregate_policy" => "release",
      "target_resolver_module" => "AllbertAssist.TestTargets",
      "target_resolver_function" => "resolve",
      "historical_metrics_aliases" => ["allbert", "core"]
    }

  defp source_authority(:app_descriptor_v1),
    do: %{
      "app_id" => "allbert",
      "module" => "AllbertAssist",
      "display_name" => "Allbert",
      "version" => "1.4.0",
      "actions" => [
        %{
          "module" => "AllbertAssist.Actions.Run",
          "name" => "run",
          "binding_sha256" => String.duplicate("1", 64)
        }
      ],
      "agents" => ["AllbertAssist.Agent"],
      "signals" => %{"emits" => ["allbert.ready"], "subscribes" => ["allbert.stop"]},
      "memory_namespace" => nil,
      "surface_provider" => nil,
      "surface_refs" => [
        %{"surface_id" => "workspace", "projection_sha256" => String.duplicate("2", 64)}
      ],
      "surface_catalog" => [
        %{
          "component" => "panel",
          "allowed_props" => ["title", "body"],
          "allowed_bindings" => ["submit", "cancel"]
        }
      ],
      "skill_root_refs" => [
        %{
          "owner_id" => "allbert_assist",
          "root_id" => "notes_files:skills",
          "projection_sha256" => String.duplicate("3", 64)
        }
      ],
      "settings_fragment_refs" => [
        %{"fragment_id" => "core", "projection_sha256" => String.duplicate("4", 64)}
      ],
      "intent_descriptor_refs" => [
        %{"intent_id" => "memory.search", "projection_sha256" => String.duplicate("5", 64)}
      ],
      "child_id" => "ignore",
      "metadata" => %{}
    }

  defp source_authority(:action_ref_v1),
    do: %{
      "kind" => "action",
      "module" => "AllbertAssist.Actions.Run",
      "name" => "run",
      "normalized_capability" => action_capability(),
      "input_schema_sha256" => String.duplicate("6", 64),
      "output_schema_sha256" => String.duplicate("7", 64)
    }

  defp source_authority(:settings_fragment_ref_v1),
    do: %{
      "fragment_id" => "core",
      "legacy_owner_id" => "acp_server",
      "source" => "core",
      "group" => "core",
      "schema_version" => 1,
      "schema" => %{
        "sample.key" => %{
          "type" => "string",
          "default" => "value",
          "writable?" => true,
          "sensitive?" => false,
          "allowed_values" => ["value", "other"],
          "min" => 0.5
        }
      },
      "defaults" => %{"sample" => %{"key" => "value"}},
      "safe_write_keys" => ["sample.z", "sample.a"],
      "metadata" => %{"label" => "Core"}
    }

  defp source_authority(:channel_descriptor_v1),
    do: %{
      "plugin_id" => "allbert_assist",
      "channel_id" => "tui",
      "adapter" => "AllbertAssist.Channels.TUI",
      "provider" => "local",
      "source" => "shipped",
      "status" => "enabled",
      "settings_prefix" => "channels.tui",
      "identity_map_key" => "channels.tui.identity_map",
      "primitives" => ["list", "typed_command"],
      "threading" => "flat",
      "streaming" => "inline",
      "session_strategy" => %{
        "strategy" => "tui_session",
        "options" => [%{"key" => "prefix", "value" => "ch_tui_"}]
      },
      "trust_class" => "local",
      "secret_refs" => [],
      "summary_fields" => ["enabled", "profile"],
      "can_create_thread" => false,
      "reply_key_type" => nil,
      "quote_ttl_ms" => nil,
      "status_update_mode" => nil,
      "child_spec" => %{
        "kind" => "module_options",
        "module" => "AllbertTUI.Supervisor",
        "options" => []
      }
    }

  defp source_authority(:surface_ref_v1),
    do: %{
      "id" => "workspace",
      "app_id" => "allbert",
      "label" => "Workspace",
      "path" => "/workspace",
      "kind" => "page",
      "zone" => nil,
      "status" => "enabled",
      "nodes" => [
        %{
          "id" => "main",
          "component" => "panel",
          "props" => %{"title" => "Workspace"},
          "bindings" => [
            %{
              "action_name" => "run",
              "action_module" => "AllbertAssist.Actions.Run",
              "permission" => "read_only",
              "app_id" => "allbert",
              "plugin_id" => nil,
              "confirmation_required?" => false
            }
          ],
          "children" => []
        }
      ],
      "fallback_text" => nil,
      "metadata" => %{}
    }

  defp source_authority(:intent_descriptor_ref_v1),
    do: %{
      "intent_id" => "memory.search",
      "app_id" => "allbert",
      "action_name" => "memory.search",
      "label" => "Search memory",
      "source" => "app",
      "source_module" => "AllbertAssist.Intents.MemorySearch",
      "destination" => nil,
      "selection_policy" => "best_match",
      "examples" => ["find my note"],
      "synonyms" => ["remember"],
      "required_slots" => ["query"],
      "optional_slots" => [],
      "slot_extractors" => %{"query" => "memory_phrase"},
      "vocabulary" => %{
        "phrases" => ["find"],
        "negative_phrases" => [],
        "selection_phrases" => ["search"],
        "selection_negative_phrases" => [],
        "clarification_phrases" => [],
        "allow_single_token_match" => true,
        "allow_required_slot_selection" => true
      },
      "handoff_required" => false,
      "routable_by_default" => true,
      "capability" => intent_capability()
    }

  defp source_authority(schema)
       when schema in [
              :skill_root_v1,
              :home_root_v1,
              :job_ref_v1,
              :store_ref_v1,
              :prompt_rule_ref_v1,
              :cli_group_ref_v1,
              :test_lane_v1
            ],
       do: %{}

  defp source_authority(:release_asset_v1), do: nil

  defp action_capability,
    do: %{
      "app_id" => nil,
      "confirmation" => nil,
      "execution_mode" => "sync",
      "exposure" => "internal",
      "notes" => nil,
      "permission" => "read_only",
      "plugin_id" => nil,
      "resumable?" => false,
      "retry_safety" => "safe",
      "skill_backed?" => false
    }

  defp intent_capability,
    do: %{
      "name" => "memory.search",
      "module" => "AllbertAssist.Actions.Run",
      "registered?" => true,
      "permission" => "read_only",
      "exposure" => "agent",
      "execution_mode" => "sync",
      "skill_backed?" => false,
      "confirmation" => nil,
      "resumable?" => false,
      "retry_safety" => "safe",
      "app_id" => "allbert",
      "plugin_id" => nil
    }

  defp row(schema, input, payload) do
    %{callback: callback, identity: identity, order: order} = row_metadata(schema, payload)

    %Row{
      schema_version: 1,
      kind: callback,
      owner_id: "allbert_assist",
      identity: identity,
      order: order,
      payload_schema: schema,
      payload: payload,
      source_authority: input.source_authority,
      m0_payload_sha256: nil
    }
  end

  defp row_metadata(:settings_fragment_ref_v1, payload),
    do: %{
      callback: :settings_fragments,
      identity: %{namespace: :fragment_id, value: payload["fragment_id"]},
      order: %{namespace: :registry_order, value: 2}
    }

  defp row_metadata(:app_descriptor_v1, payload),
    do: %{
      callback: :apps,
      identity: %{namespace: :app_id, value: payload["app_id"]},
      order: %{namespace: :registry_order, value: 3}
    }

  defp row_metadata(:release_asset_v1, payload),
    do: %{
      callback: :release_assets,
      identity: %{namespace: :asset_id, value: payload["asset_id"]},
      order: %{namespace: :lexical, value: payload["asset_id"]}
    }

  defp row_metadata(:test_lane_v1, payload),
    do: %{
      callback: :test_lanes,
      identity: %{namespace: :owner_id, value: payload["owner_id"]},
      order: %{namespace: :lexical, value: payload["owner_id"]}
    }

  defp row_metadata(:action_ref_v1, payload),
    do: %{
      callback: :actions,
      identity: %{namespace: :action_name, value: payload["name"]},
      order: %{namespace: :registry_order, value: 7}
    }

  defp row_metadata(:channel_descriptor_v1, payload),
    do: %{
      callback: :channels,
      identity: %{namespace: :channel_id, value: payload["channel_id"]},
      order: %{namespace: :registry_order, value: 7}
    }

  defp contribution, do: contribution(owner(), "beam-allbert-assist")

  defp contribution(owner, component) do
    %Contribution{
      schema_version: 1,
      owner: owner,
      implementation_module: __MODULE__,
      descriptor: %Descriptor{
        schema_version: 1,
        id: owner.id,
        application: owner.application,
        application_version: "1.4.0",
        capability_tier: :native,
        provenance: %{source: :signed_release, component: component},
        registry_order: 1
      },
      source_lane: :native,
      owner_order: %Order{
        schema_version: 1,
        namespace: owner.kind,
        value: 1
      },
      compatibility: %Compatibility{
        schema_version: 1,
        kind: :native,
        legacy_id: nil,
        alias_of: nil,
        trust: :trusted,
        enabled: true
      },
      callbacks: Map.new(@callbacks, &{&1, []})
    }
  end

  defp owner,
    do: %Owner{
      schema_version: 1,
      kind: :compiled_pack,
      id: "allbert_assist",
      application: :allbert_assist
    }

  defp input_for_contribution(:app_descriptor_v1, input, contribution) do
    input
    |> update_authority(fn authority ->
      Map.update!(authority, "skill_root_refs", fn refs ->
        Enum.map(refs, &Map.put(&1, "owner_id", contribution.owner.id))
      end)
    end)
    |> with_recomputed_digest(:app_descriptor_v1)
  end

  defp input_for_contribution(:settings_fragment_ref_v1, input, contribution) do
    input
    |> update_payload(&Map.put(&1, "owner_id", contribution.owner.id))
    |> with_recomputed_digest(:settings_fragment_ref_v1)
  end

  defp input_for_contribution(:release_asset_v1, input, contribution) do
    update_payload(input, fn payload ->
      Map.put(payload, "component", contribution.descriptor.provenance.component)
    end)
  end

  defp input_for_contribution(:test_lane_v1, input, contribution) do
    input
    |> update_payload(&Map.put(&1, "application", Atom.to_string(contribution.owner.application)))
    |> with_recomputed_digest(:test_lane_v1)
  end

  defp with_recomputed_digest(input, schema) do
    digest_field = reference_digest_field(schema)
    digest = RowSchemas.reference_digest_for!(schema, input)
    update_payload(input, &Map.put(&1, digest_field, digest))
  end

  defp normalized_payload(schema, input) do
    schema |> RowSchemas.normalize!(input) |> RowSchemas.canonical_projection()
  end

  defp update_payload(%Input{} = input, fun), do: %{input | payload: fun.(input.payload)}

  defp update_authority(%Input{} = input, fun),
    do: %{input | source_authority: fun.(input.source_authority)}

  defp owner_fields(:app_descriptor_v1), do: []
  defp owner_fields(:settings_fragment_ref_v1), do: ["owner_id"]
  defp owner_fields(:release_asset_v1), do: ["component"]
  defp owner_fields(:test_lane_v1), do: ["application"]

  defp reference_digest_field(:app_descriptor_v1), do: "contract_sha256"
  defp reference_digest_field(:action_ref_v1), do: "binding_sha256"
  defp reference_digest_field(:release_asset_v1), do: nil
  defp reference_digest_field(_schema), do: "projection_sha256"

  defp row_digest(schema, payload_without_digest, source_authority) do
    bytes =
      canonical_json(%{
        "payload" => payload_without_digest,
        "source_authority" => source_authority
      })

    :crypto.hash(:sha256, "allbert.pack.row.#{schema}.v1\0" <> bytes)
    |> Base.encode16(case: :lower)
  end

  defp contract(contracts, schema),
    do: Enum.find(contracts, &(&1["payload_schema"] == Atom.to_string(schema)))

  defp field_contract(contracts, schema, field),
    do: Enum.find(contract(contracts, schema)["fields"], &(&1["name"] == field))

  defp authority_field_contract(contracts, schema, field),
    do:
      Enum.find(
        contract(contracts, schema)["source_authority"]["fields"],
        &(&1["name"] == field)
      )

  defp canonical_json(value) when is_map(value) do
    encoded =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, nested} ->
        canonical_json(key) <> ":" <> canonical_json(nested)
      end)

    "{" <> encoded <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end

  defp canonical_json(value) when is_integer(value), do: Integer.to_string(value)
  defp canonical_json(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp canonical_json(nil), do: "null"
  defp canonical_json(true), do: "true"
  defp canonical_json(false), do: "false"

  defp canonical_json?(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: true

  defp canonical_json?(value) when is_list(value), do: Enum.all?(value, &canonical_json?/1)

  defp canonical_json?(value) when is_map(value),
    do: Enum.all?(value, fn {key, nested} -> is_binary(key) and canonical_json?(nested) end)

  defp canonical_json?(_value), do: false
end
