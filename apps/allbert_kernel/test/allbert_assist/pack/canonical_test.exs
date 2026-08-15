defmodule AllbertAssist.Pack.CanonicalTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.Pack.{ActionBinding, Compatibility, CompatibilityAlias}
  alias AllbertAssist.Pack.Canonical
  alias AllbertAssist.Pack.{ChildSpecProjection, CompatibilityDiagnostic}
  alias AllbertAssist.Pack.{Contribution, Descriptor, Order, Owner, OwnerRef, Row, RowSchemas}
  alias AllbertAssist.Pack.{PathSegment, ValidationDiagnostic}
  alias AllbertAssist.Pack.Registry.{Candidate, Snapshot}
  alias AllbertAssist.Pack.RowSchemas.Input
  alias AllbertAssist.Pack.Target

  test "candidate schema versions outside v1 return one typed validation diagnostic" do
    candidate = %Candidate{
      schema_version: 2,
      contributions: [],
      action_bindings: [],
      compatibility_aliases: [],
      compatibility_diagnostics: []
    }

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :unsupported_schema_version,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "schema_version"}
                ],
                owner: nil,
                detail: %{expected: 1, actual: 2}
              }
            ]} = Canonical.build_snapshot(candidate, :shadow)
  end

  test "candidate schema version type and range failures stay typed" do
    for {schema_version, code, detail} <- [
          {:one, :invalid_type, %{expected: "non_neg_integer", actual: "atom"}},
          {-1, :invalid_value, %{reason: :non_neg_integer_required}}
        ] do
      candidate = %Candidate{
        schema_version: schema_version,
        contributions: [],
        action_bindings: [],
        compatibility_aliases: [],
        compatibility_diagnostics: []
      }

      assert {:error,
              [
                %ValidationDiagnostic{
                  schema_version: 1,
                  code: ^code,
                  path: [
                    %PathSegment{schema_version: 1, kind: :field, value: "schema_version"}
                  ],
                  owner: nil,
                  detail: ^detail
                }
              ]} = Canonical.build_snapshot(candidate, :shadow)
    end
  end

  test "candidate envelope collection types reject with stable field paths" do
    candidate = %Candidate{
      schema_version: 1,
      contributions: :not_a_list,
      action_bindings: [],
      compatibility_aliases: [],
      compatibility_diagnostics: []
    }

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_type,
                path: [%PathSegment{schema_version: 1, kind: :field, value: "contributions"}],
                owner: nil,
                detail: %{expected: "list", actual: "atom"}
              }
            ]} = Canonical.build_snapshot(candidate, :shadow)
  end

  test "candidate and snapshot envelopes reject missing struct fields without raising" do
    missing_candidate = candidate([]) |> Map.delete(:contributions)

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :missing_field,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"}
                ],
                owner: nil,
                detail: %{field: "contributions"}
              }
            ]} = Canonical.build_snapshot(missing_candidate, :shadow)

    assert {:ok, snapshot} = Canonical.build_snapshot(candidate([]), :shadow)
    missing_snapshot = Map.delete(snapshot, :behavior_digest)

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :missing_field,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "behavior_digest"}
                ],
                owner: nil,
                detail: %{field: "behavior_digest"}
              }
            ]} = Canonical.snapshot_bytes(missing_snapshot)
  end

  test "nested structs reject missing fields without raising" do
    contribution = legacy_contribution("legacy_one", 1) |> Map.delete(:callbacks)

    assert_contribution_error(
      contribution,
      :missing_field,
      contribution_field_path("legacy_one", ["callbacks"]),
      %{field: "callbacks"}
    )
  end

  test "every candidate collection field is validated before traversal" do
    candidate = candidate(action_bindings: :not_a_list)

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_type,
                path: [%PathSegment{schema_version: 1, kind: :field, value: "action_bindings"}],
                owner: nil,
                detail: %{expected: "list", actual: "atom"}
              }
            ]} = Canonical.build_snapshot(candidate, :shadow)
  end

  test "snapshot_bytes returns typed diagnostics instead of partial bytes" do
    snapshot = %Snapshot{
      schema_version: 2,
      publication: :shadow,
      behavior_digest: String.duplicate("0", 64),
      contributions: [],
      effective_actions: [],
      compatibility_aliases: [],
      compatibility_diagnostics: []
    }

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :unsupported_schema_version,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "schema_version"}
                ],
                owner: nil,
                detail: %{expected: 1, actual: 2}
              }
            ]} = Canonical.snapshot_bytes(snapshot)
  end

  test "snapshot schema version type and range failures stay typed" do
    assert {:ok, valid} = Canonical.build_snapshot(candidate([]), :shadow)

    for {schema_version, code, detail} <- [
          {:one, :invalid_type, %{expected: "non_neg_integer", actual: "atom"}},
          {-1, :invalid_value, %{reason: :non_neg_integer_required}}
        ] do
      snapshot = %{valid | schema_version: schema_version}

      assert {:error,
              [
                %ValidationDiagnostic{
                  schema_version: 1,
                  code: ^code,
                  path: [
                    %PathSegment{schema_version: 1, kind: :field, value: "schema_version"}
                  ],
                  owner: nil,
                  detail: ^detail
                }
              ]} = Canonical.snapshot_bytes(snapshot)
    end
  end

  test "a typed contribution has an explicit canonical JSON projection" do
    candidate = candidate(contributions: [legacy_contribution("legacy_one", 2)])

    assert {:ok, snapshot} = Canonical.build_snapshot(candidate, :shadow)
    assert {:ok, bytes} = Canonical.snapshot_bytes(snapshot)

    assert bytes ==
             ~s({"compatibility_aliases":[],"compatibility_diagnostics":[],"contributions":[{"callbacks":{"actions":[],"apps":[],"channels":[],"cli_groups":[],"home_roots":[],"intent_descriptors":[],"jobs":[],"prompt_rules":[],"release_assets":[],"settings_fragments":[],"settings_migrations":[],"skill_roots":[],"stores":[],"surfaces":[],"test_lanes":[]},"compatibility":{"alias_of":null,"enabled":true,"kind":"legacy_plugin","legacy_id":"legacy_one","schema_version":1,"trust":"pending"},"descriptor":null,"implementation_module":"AllbertAssist.Pack.CanonicalTest","owner":{"application":null,"id":"legacy_one","kind":"legacy_plugin","schema_version":1},"owner_order":{"namespace":"legacy_plugin","schema_version":1,"value":2},"schema_version":1,"source_lane":"legacy_plugin"}],"effective_actions":[],"schema_version":1})

    assert snapshot.behavior_digest ==
             :sha256
             |> :crypto.hash("allbert.pack.snapshot.v1\0" <> bytes)
             |> Base.encode16(case: :lower)

    assert {:ok, ^bytes} = Canonical.snapshot_bytes(snapshot)
  end

  test "candidate collections reject untyped entries at an index path" do
    candidate = candidate(action_bindings: [42])

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_type,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                  %PathSegment{schema_version: 1, kind: :index, value: 0}
                ],
                owner: nil,
                detail: %{expected: "ActionBinding", actual: "integer"}
              }
            ]} = Canonical.build_snapshot(candidate, :shadow)
  end

  test "contribution input permutation cannot change snapshot order, bytes, or digest" do
    first = legacy_contribution("first", 3)
    second = legacy_contribution("second", 7)

    assert {:ok, left_snapshot} =
             Canonical.build_snapshot(candidate(contributions: [second, first]), :shadow)

    assert {:ok, right_snapshot} =
             Canonical.build_snapshot(candidate(contributions: [first, second]), :shadow)

    assert {:ok, left_bytes} = Canonical.snapshot_bytes(left_snapshot)
    assert {:ok, right_bytes} = Canonical.snapshot_bytes(right_snapshot)

    assert Enum.map(left_snapshot.contributions, & &1.owner.id) == ["first", "second"]
    assert left_snapshot == right_snapshot
    assert left_bytes == right_bytes
  end

  test "duplicate owner-order tokens reject before any snapshot bytes are returned" do
    candidate =
      candidate(
        contributions: [legacy_contribution("second", 3), legacy_contribution("first", 3)]
      )

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :duplicate_order,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "second"},
                  %PathSegment{schema_version: 1, kind: :field, value: "owner_order"}
                ],
                owner: %OwnerRef{
                  schema_version: 1,
                  kind: :legacy_plugin,
                  id: "second"
                },
                detail: %{identity: "legacy_plugin:3"}
              }
            ]} = Canonical.build_snapshot(candidate, :shadow)
  end

  test "duplicate contribution owner identities reject without deduplication" do
    candidate =
      candidate(
        contributions: [
          legacy_contribution("duplicate", 7),
          legacy_contribution("duplicate", 3)
        ]
      )

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :duplicate_identity,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "duplicate"}
                ],
                owner: %OwnerRef{
                  schema_version: 1,
                  kind: :legacy_plugin,
                  id: "duplicate"
                },
                detail: %{identity: "legacy_plugin:duplicate"}
              }
            ]} = Canonical.build_snapshot(candidate, :shadow)
  end

  test "contribution owner ids are globally unique across owner kinds" do
    legacy = legacy_contribution("same", 1)
    declared = declared_contribution("same")

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :duplicate_identity,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "same"}
                ],
                owner: %OwnerRef{schema_version: 1, kind: :declared_pack, id: "same"},
                detail: %{identity: "declared_pack:same"}
              }
            ]} =
             Canonical.build_snapshot(candidate(contributions: [declared, legacy]), :shadow)
  end

  test "contribution nested records and callback containers are closed" do
    owner_path = [
      %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
      %PathSegment{schema_version: 1, kind: :index, value: 0},
      %PathSegment{schema_version: 1, kind: :field, value: "owner"}
    ]

    assert_contribution_error(
      %{legacy_contribution("legacy_one", 1) | owner: nil},
      :invalid_type,
      owner_path,
      %{expected: "Owner", actual: "atom"}
    )

    missing_callbacks =
      legacy_contribution("legacy_one", 1)
      |> Map.update!(:callbacks, &Map.delete(&1, :apps))

    callback_base = [
      %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
      %PathSegment{schema_version: 1, kind: :identity, value: "legacy_one"},
      %PathSegment{schema_version: 1, kind: :field, value: "callbacks"}
    ]

    assert_contribution_error(
      missing_callbacks,
      :missing_field,
      callback_base ++ [%PathSegment{schema_version: 1, kind: :field, value: "apps"}],
      %{field: "apps"}
    )

    non_list_callbacks = put_in(legacy_contribution("legacy_one", 1).callbacks.apps, :bad)

    assert_contribution_error(
      non_list_callbacks,
      :invalid_type,
      callback_base ++ [%PathSegment{schema_version: 1, kind: :field, value: "apps"}],
      %{expected: "list", actual: "atom"}
    )

    wrong_row = skill_root_row("legacy_one", "sample")
    wrong_container = put_in(legacy_contribution("legacy_one", 1).callbacks.apps, [wrong_row])

    assert_contribution_error(
      wrong_container,
      :invalid_value,
      callback_base ++
        [
          %PathSegment{schema_version: 1, kind: :field, value: "apps"},
          %PathSegment{schema_version: 1, kind: :index, value: 0},
          %PathSegment{schema_version: 1, kind: :field, value: "kind"}
        ],
      %{reason: :callback_container_mismatch}
    )
  end

  test "owner lane order and compatibility semantics are paired by contribution kind" do
    legacy = legacy_contribution("legacy_one", 2)

    cases = [
      {%{legacy | schema_version: 2}, ["schema_version"], :unsupported_schema_version,
       %{expected: 1, actual: 2}},
      {%{legacy | source_lane: :native}, ["source_lane"], :invalid_value,
       %{reason: :owner_lane_mismatch}},
      {put_in(legacy.owner_order.namespace, :compiled_pack), ["owner_order", "namespace"],
       :invalid_value, %{reason: :owner_order_mismatch}},
      {put_in(legacy.owner_order.value, 0), ["owner_order", "value"], :invalid_value,
       %{reason: :positive_integer_required}},
      {%{legacy | descriptor: compiled_contribution().descriptor}, ["descriptor"], :invalid_value,
       %{reason: :descriptor_forbidden}},
      {put_in(legacy.compatibility.kind, :native), ["compatibility", "kind"], :invalid_value,
       %{reason: :owner_compatibility_mismatch}},
      {put_in(legacy.compatibility.trust, :other), ["compatibility", "trust"], :invalid_value,
       %{reason: :unsupported_trust}},
      {put_in(legacy.compatibility.enabled, :yes), ["compatibility", "enabled"], :invalid_type,
       %{expected: "boolean", actual: "atom"}}
    ]

    for {contribution, fields, code, detail} <- cases do
      path =
        [
          %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
          %PathSegment{schema_version: 1, kind: :identity, value: "legacy_one"}
        ] ++
          Enum.map(fields, &%PathSegment{schema_version: 1, kind: :field, value: &1})

      assert_contribution_error(contribution, code, path, detail)
    end
  end

  test "compiled and declared contribution semantics fail closed" do
    compiled = compiled_contribution()

    assert_contribution_error(
      put_in(compiled.owner.application, :other),
      :owner_mismatch,
      contribution_field_path("allbert_kernel", ["owner", "application"]),
      %{expected: "allbert_kernel", actual: "other"}
    )

    assert_contribution_error(
      put_in(compiled.owner_order.value, 9),
      :owner_mismatch,
      contribution_field_path("allbert_kernel", ["owner_order", "value"]),
      %{expected: "0", actual: "9"}
    )

    assert_contribution_error(
      put_in(compiled.compatibility.trust, :pending),
      :invalid_value,
      contribution_field_path("allbert_kernel", ["compatibility", "trust"]),
      %{reason: :signed_pack_trust_required}
    )

    declared = declared_contribution("declared_one")

    assert_contribution_error(
      put_in(declared.owner_order.value, "other"),
      :owner_mismatch,
      contribution_field_path("declared_one", ["owner_order", "value"]),
      %{expected: "declared_one", actual: "other"}
    )

    assert {:ok, %Snapshot{}} =
             Canonical.build_snapshot(candidate(contributions: [declared]), :shadow)
  end

  test "declared contribution applications must reconcile to a compiled owner" do
    declared = put_in(declared_contribution("declared_one").owner.application, :missing_app)

    assert_contribution_error(
      declared,
      :invalid_value,
      contribution_field_path("declared_one", ["owner", "application"]),
      %{reason: :unreconciled_declared_application}
    )

    reconciled =
      put_in(declared_contribution("declared_one").owner.application, :allbert_kernel)

    assert {:ok, %Snapshot{}} =
             Canonical.build_snapshot(
               candidate(contributions: [reconciled, compiled_contribution()]),
               :shadow
             )
  end

  test "declared contributions are code-free and skill-root-only" do
    owner_id = "acme.skills"

    skill_root =
      skill_root_row(
        owner_id,
        "acme.skills:plugins/acme.skills",
        "plugins/acme.skills"
      )

    declared =
      owner_id
      |> declared_contribution()
      |> put_in([Access.key!(:callbacks), Access.key!(:skill_roots)], [skill_root])

    assert {:ok, %Snapshot{}} =
             Canonical.build_snapshot(candidate(contributions: [declared]), :shadow)

    settings = settings_row_with_float(owner_id, "settings", 1)
    with_settings = put_in(declared.callbacks.settings_fragments, [settings])

    assert_contribution_error(
      with_settings,
      :invalid_value,
      contribution_field_path(owner_id, ["callbacks", "settings_fragments"]),
      %{reason: :declared_callback_not_data_only}
    )

    action = action_row(owner_id, "declared_action", 1)
    with_action = put_in(declared.callbacks.actions, [action])

    assert_contribution_error(
      with_action,
      :invalid_value,
      contribution_field_path(owner_id, ["callbacks", "actions"]),
      %{reason: :declared_callback_not_data_only}
    )
  end

  test "disabled declared contributions are inert and use declared-owner evidence" do
    owner_id = "acme.skills"
    disabled = put_in(declared_contribution(owner_id).compatibility.enabled, false)
    diagnostic = disabled_plugin_diagnostic(owner_id, :declared_pack)

    assert {:ok, %Snapshot{}} =
             Canonical.build_snapshot(
               candidate(
                 contributions: [disabled],
                 compatibility_diagnostics: [diagnostic]
               ),
               :shadow
             )

    with_root =
      put_in(
        disabled.callbacks.skill_roots,
        [skill_root_row(owner_id, "acme.skills:plugins/acme.skills/skills")]
      )

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: ^owner_id},
                  %PathSegment{schema_version: 1, kind: :field, value: "callbacks"},
                  %PathSegment{schema_version: 1, kind: :field, value: "skill_roots"}
                ],
                owner: %OwnerRef{
                  schema_version: 1,
                  kind: :declared_pack,
                  id: ^owner_id
                },
                detail: %{reason: :disabled_contribution_must_be_inert}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(
                 contributions: [with_root],
                 compatibility_diagnostics: [diagnostic]
               ),
               :shadow
             )
  end

  test "skill-root trust policy exactly matches declared and legacy contribution trust" do
    cases = [
      {:declared_pack, declared_contribution("declared_one"),
       skill_root_row(
         "declared_one",
         "declared_one:plugins/declared_one",
         "plugins/declared_one",
         "trusted"
       )},
      {:legacy_plugin, legacy_contribution("legacy_one", 1),
       skill_root_row("legacy_one", "legacy_root", "skills/legacy_root", "trusted")}
    ]

    Enum.each(cases, fn {kind, contribution, row} ->
      contribution = put_in(contribution.callbacks.skill_roots, [row])
      owner_id = contribution.owner.id
      root_id = row.payload["root_id"]

      assert {:error,
              [
                %ValidationDiagnostic{
                  schema_version: 1,
                  code: :invalid_value,
                  path: [
                    %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                    %PathSegment{schema_version: 1, kind: :identity, value: ^owner_id},
                    %PathSegment{schema_version: 1, kind: :field, value: "callbacks"},
                    %PathSegment{schema_version: 1, kind: :field, value: "skill_roots"},
                    %PathSegment{schema_version: 1, kind: :identity, value: ^root_id},
                    %PathSegment{schema_version: 1, kind: :field, value: "payload"},
                    %PathSegment{schema_version: 1, kind: :field, value: "trust_policy"}
                  ],
                  owner: %OwnerRef{
                    schema_version: 1,
                    kind: ^kind,
                    id: ^owner_id
                  },
                  detail: %{reason: :skill_root_trust_mismatch}
                }
              ]} = Canonical.build_snapshot(candidate(contributions: [contribution]), :shadow)
    end)
  end

  test "declared skill roots stay inside their exact owner namespace" do
    owner_id = "acme.skills"
    owner = %OwnerRef{schema_version: 1, kind: :declared_pack, id: owner_id}

    descendant =
      skill_root_row(
        owner_id,
        "acme.skills:plugins/acme.skills/nested",
        "plugins/acme.skills/nested"
      )

    valid = put_in(declared_contribution(owner_id).callbacks.skill_roots, [descendant])

    assert {:ok, %Snapshot{}} =
             Canonical.build_snapshot(candidate(contributions: [valid]), :shadow)

    escaped_path = "plugins/acme.skills-other"

    escaped =
      skill_root_row(
        owner_id,
        "acme.skills:#{escaped_path}",
        escaped_path
      )

    escaped_contribution =
      put_in(declared_contribution(owner_id).callbacks.skill_roots, [escaped])

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: ^owner_id},
                  %PathSegment{schema_version: 1, kind: :field, value: "callbacks"},
                  %PathSegment{schema_version: 1, kind: :field, value: "skill_roots"},
                  %PathSegment{
                    schema_version: 1,
                    kind: :identity,
                    value: "acme.skills:plugins/acme.skills-other"
                  },
                  %PathSegment{schema_version: 1, kind: :field, value: "payload"},
                  %PathSegment{schema_version: 1, kind: :field, value: "relative_path"}
                ],
                owner: ^owner,
                detail: %{reason: :declared_skill_root_path_mismatch}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(contributions: [escaped_contribution]),
               :shadow
             )

    relative_path = "plugins/acme.skills/nested"
    wrong_root_id = "other:#{relative_path}"
    wrong_id = skill_root_row(owner_id, wrong_root_id, relative_path)

    wrong_id_contribution =
      put_in(declared_contribution(owner_id).callbacks.skill_roots, [wrong_id])

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: ^owner_id},
                  %PathSegment{schema_version: 1, kind: :field, value: "callbacks"},
                  %PathSegment{schema_version: 1, kind: :field, value: "skill_roots"},
                  %PathSegment{schema_version: 1, kind: :identity, value: ^wrong_root_id},
                  %PathSegment{schema_version: 1, kind: :field, value: "payload"},
                  %PathSegment{schema_version: 1, kind: :field, value: "root_id"}
                ],
                owner: ^owner,
                detail: %{reason: :declared_skill_root_id_mismatch}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(contributions: [wrong_id_contribution]),
               :shadow
             )
  end

  test "disabled legacy contributions are inert and carry exactly one frozen diagnostic" do
    disabled = disabled_legacy_contribution("disabled_plugin", 1)
    diagnostic = disabled_plugin_diagnostic("disabled_plugin")

    with_row = put_in(disabled.callbacks.skill_roots, [skill_root_row("disabled_plugin", "root")])

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "disabled_plugin"},
                  %PathSegment{schema_version: 1, kind: :field, value: "callbacks"},
                  %PathSegment{schema_version: 1, kind: :field, value: "skill_roots"}
                ],
                owner: %OwnerRef{
                  schema_version: 1,
                  kind: :legacy_plugin,
                  id: "disabled_plugin"
                },
                detail: %{reason: :disabled_contribution_must_be_inert}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(
                 contributions: [with_row],
                 compatibility_diagnostics: [diagnostic]
               ),
               :shadow
             )

    assert_contribution_error(
      disabled,
      :invalid_value,
      contribution_field_path("disabled_plugin", ["compatibility", "enabled"]),
      %{reason: :missing_disabled_plugin_diagnostic}
    )

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "disabled_plugin"},
                  %PathSegment{schema_version: 1, kind: :field, value: "compatibility"},
                  %PathSegment{schema_version: 1, kind: :field, value: "enabled"}
                ],
                detail: %{reason: :multiple_disabled_plugin_diagnostics}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(
                 contributions: [disabled],
                 compatibility_diagnostics: [diagnostic, diagnostic]
               ),
               :shadow
             )

    assert {:ok, %Snapshot{}} =
             Canonical.build_snapshot(
               candidate(
                 contributions: [disabled],
                 compatibility_diagnostics: [diagnostic]
               ),
               :shadow
             )
  end

  test "disabled legacy contributions cannot own an effective action binding" do
    owner_id = "disabled_plugin"
    disabled = disabled_legacy_contribution(owner_id, 1)
    binding = action_binding("disabled_action", 1, owner_id)

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "disabled_action"}
                ],
                owner: %OwnerRef{
                  schema_version: 1,
                  kind: :legacy_plugin,
                  id: ^owner_id
                },
                detail: %{reason: :disabled_contribution_effective_binding}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(
                 contributions: [disabled],
                 action_bindings: [binding],
                 compatibility_diagnostics: [disabled_plugin_diagnostic(owner_id)]
               ),
               :shadow
             )
  end

  test "legacy contribution ownership cannot acquire an OTP application" do
    contribution = legacy_contribution("legacy_one", 2)
    contribution = put_in(contribution.owner.application, :legacy_app)

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :owner_mismatch,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "legacy_one"},
                  %PathSegment{schema_version: 1, kind: :field, value: "owner"},
                  %PathSegment{schema_version: 1, kind: :field, value: "application"}
                ],
                owner: %OwnerRef{
                  schema_version: 1,
                  kind: :legacy_plugin,
                  id: "legacy_one"
                },
                detail: %{expected: "nil", actual: "legacy_app"}
              }
            ]} = Canonical.build_snapshot(candidate(contributions: [contribution]), :shadow)
  end

  test "compiled and legacy contributions require an executable implementation module" do
    contribution = %{legacy_contribution("legacy_one", 2) | implementation_module: nil}
    owner = %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "legacy_one"}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "legacy_one"},
                  %PathSegment{
                    schema_version: 1,
                    kind: :field,
                    value: "implementation_module"
                  }
                ],
                owner: ^owner,
                detail: %{reason: :implementation_module_required}
              }
            ]} = Canonical.build_snapshot(candidate(contributions: [contribution]), :shadow)
  end

  test "declared contributions cannot acquire an implementation module" do
    contribution = %Contribution{
      schema_version: 1,
      owner: %Owner{
        schema_version: 1,
        kind: :declared_pack,
        id: "declared_one",
        application: nil
      },
      implementation_module: __MODULE__,
      descriptor: nil,
      source_lane: :declared,
      owner_order: %Order{
        schema_version: 1,
        namespace: :declared_pack,
        value: "declared_one"
      },
      compatibility: %Compatibility{
        schema_version: 1,
        kind: :declared,
        legacy_id: nil,
        alias_of: nil,
        trust: :pending,
        enabled: false
      },
      callbacks: empty_callbacks()
    }

    owner = %OwnerRef{schema_version: 1, kind: :declared_pack, id: "declared_one"}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "declared_one"},
                  %PathSegment{
                    schema_version: 1,
                    kind: :field,
                    value: "implementation_module"
                  }
                ],
                owner: ^owner,
                detail: %{reason: :declared_contribution_cannot_grant_code}
              }
            ]} = Canonical.build_snapshot(candidate(contributions: [contribution]), :shadow)
  end

  test "contribution owner ids must be canonical strings" do
    contribution = legacy_contribution(" legacy_one", 2)

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :index, value: 0},
                  %PathSegment{schema_version: 1, kind: :field, value: "owner"},
                  %PathSegment{schema_version: 1, kind: :field, value: "id"}
                ],
                owner: nil,
                detail: %{reason: :canonical_string_required}
              }
            ]} = Canonical.build_snapshot(candidate(contributions: [contribution]), :shadow)
  end

  test "legacy compatibility identity must match its contribution owner" do
    contribution = legacy_contribution("legacy_one", 2)
    contribution = put_in(contribution.compatibility.legacy_id, "another_owner")
    owner = %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "legacy_one"}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :owner_mismatch,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "legacy_one"},
                  %PathSegment{schema_version: 1, kind: :field, value: "compatibility"},
                  %PathSegment{schema_version: 1, kind: :field, value: "legacy_id"}
                ],
                owner: ^owner,
                detail: %{expected: "legacy_one", actual: "another_owner"}
              }
            ]} = Canonical.build_snapshot(candidate(contributions: [contribution]), :shadow)
  end

  test "compiled contributions project their validated descriptor explicitly" do
    contribution = compiled_contribution()

    assert {:ok, snapshot} =
             Canonical.build_snapshot(candidate(contributions: [contribution]), :shadow)

    assert {:ok, bytes} = Canonical.snapshot_bytes(snapshot)

    assert bytes =~
             ~s("descriptor":{"application":"allbert_kernel","application_version":"1.4.0","capability_tier":"kernel","id":"allbert_kernel","provenance":{"component":"beam-allbert-kernel","source":"signed_release"},"registry_order":0,"schema_version":1})
  end

  test "compiled descriptor identity must match its contribution owner" do
    contribution = compiled_contribution()
    contribution = put_in(contribution.descriptor.id, "another_pack")
    owner = %OwnerRef{schema_version: 1, kind: :compiled_pack, id: "allbert_kernel"}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :owner_mismatch,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "allbert_kernel"},
                  %PathSegment{schema_version: 1, kind: :field, value: "descriptor"},
                  %PathSegment{schema_version: 1, kind: :field, value: "id"}
                ],
                owner: ^owner,
                detail: %{expected: "allbert_kernel", actual: "another_pack"}
              }
            ]} = Canonical.build_snapshot(candidate(contributions: [contribution]), :shadow)
  end

  test "compatibility evidence uses an explicit canonical diagnostic projection" do
    diagnostic = %CompatibilityDiagnostic{
      schema_version: 1,
      code: :legacy_registry,
      severity: :warning,
      path: [
        %PathSegment{schema_version: 1, kind: :field, value: "plugins"},
        %PathSegment{schema_version: 1, kind: :index, value: 3}
      ],
      owner: %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "legacy_one"},
      detail: %{source_lane: :legacy_plugin, legacy_index: 3}
    }

    assert {:ok, snapshot} =
             Canonical.build_snapshot(
               candidate(compatibility_diagnostics: [diagnostic]),
               :shadow
             )

    assert {:ok, bytes} = Canonical.snapshot_bytes(snapshot)

    assert bytes ==
             ~s({"compatibility_aliases":[],"compatibility_diagnostics":[{"code":"legacy_registry","detail":{"legacy_index":3,"source_lane":"legacy_plugin"},"owner":{"id":"legacy_one","kind":"legacy_plugin","schema_version":1},"path":[{"kind":"field","schema_version":1,"value":"plugins"},{"kind":"index","schema_version":1,"value":3}],"schema_version":1,"severity":"warning"}],"contributions":[],"effective_actions":[],"schema_version":1})
  end

  test "compatibility diagnostics close nested path owner and detail records" do
    diagnostic = legacy_diagnostic()
    base = [%PathSegment{schema_version: 1, kind: :field, value: "compatibility_diagnostics"}]

    assert_diagnostic_error(
      Map.delete(diagnostic, :detail),
      :missing_field,
      base ++
        [
          %PathSegment{schema_version: 1, kind: :index, value: 0},
          %PathSegment{schema_version: 1, kind: :field, value: "detail"}
        ],
      %{field: "detail"}
    )

    assert_diagnostic_error(
      %{diagnostic | schema_version: 2},
      :unsupported_schema_version,
      base ++
        [
          %PathSegment{schema_version: 1, kind: :index, value: 0},
          %PathSegment{schema_version: 1, kind: :field, value: "schema_version"}
        ],
      %{expected: 1, actual: 2}
    )

    bad_segment = %PathSegment{schema_version: 1, kind: :other, value: "plugins"}

    assert_diagnostic_error(
      %{diagnostic | path: [bad_segment]},
      :invalid_value,
      base ++
        [
          %PathSegment{schema_version: 1, kind: :index, value: 0},
          %PathSegment{schema_version: 1, kind: :field, value: "path"},
          %PathSegment{schema_version: 1, kind: :index, value: 0},
          %PathSegment{schema_version: 1, kind: :field, value: "kind"}
        ],
      %{reason: :unsupported_path_segment_kind}
    )

    invalid_owner = %{diagnostic.owner | kind: :other}

    assert_diagnostic_error(
      %{diagnostic | owner: invalid_owner},
      :invalid_value,
      base ++
        [
          %PathSegment{schema_version: 1, kind: :index, value: 0},
          %PathSegment{schema_version: 1, kind: :field, value: "owner"},
          %PathSegment{schema_version: 1, kind: :field, value: "kind"}
        ],
      %{reason: :unsupported_owner_kind}
    )

    assert_diagnostic_error(
      %{diagnostic | detail: Map.put(diagnostic.detail, :extra, true)},
      :unknown_field,
      base ++
        [
          %PathSegment{schema_version: 1, kind: :index, value: 0},
          %PathSegment{schema_version: 1, kind: :field, value: "detail"},
          %PathSegment{schema_version: 1, kind: :field, value: "extra"}
        ],
      %{field: "extra"}
    )
  end

  test "child spec and collision diagnostic invariants fail closed" do
    owner_id = "plugin_one"

    child_spec = %ChildSpecProjection{
      schema_version: 1,
      id: "worker",
      start_module: "AllbertAssist.Worker",
      start_function: "start_link",
      start_arity: 1,
      start_args_sha256: String.duplicate("d", 64),
      restart: "permanent",
      shutdown: 5_000,
      type: "worker"
    }

    child_diagnostic = %CompatibilityDiagnostic{
      schema_version: 1,
      code: :child_spec,
      severity: :warning,
      path: [
        %PathSegment{schema_version: 1, kind: :field, value: "plugins"},
        %PathSegment{schema_version: 1, kind: :identity, value: owner_id},
        %PathSegment{schema_version: 1, kind: :field, value: "children"}
      ],
      owner: %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: owner_id},
      detail: %{child_spec: child_spec}
    }

    assert {:ok, %Snapshot{}} =
             Canonical.build_snapshot(
               candidate(
                 contributions: [legacy_contribution(owner_id, 1)],
                 compatibility_diagnostics: [child_diagnostic]
               ),
               :shadow
             )

    assert_diagnostic_error(
      %{child_diagnostic | severity: :error},
      :invalid_value,
      diagnostic_field_path(["severity"]),
      %{reason: :child_spec_warning_required}
    )

    assert_diagnostic_error(
      %{child_diagnostic | path: []},
      :invalid_value,
      diagnostic_field_path(["path"]),
      %{reason: :child_spec_path_mismatch}
    )

    compiled_owner = %OwnerRef{
      schema_version: 1,
      kind: :compiled_pack,
      id: "allbert_kernel"
    }

    assert_diagnostic_error(
      %{child_diagnostic | owner: compiled_owner},
      :invalid_value,
      diagnostic_field_path(["owner"]),
      %{reason: :child_spec_owner_not_enabled_legacy}
    )

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{
                    schema_version: 1,
                    kind: :field,
                    value: "compatibility_diagnostics"
                  },
                  %PathSegment{schema_version: 1, kind: :index, value: 1}
                ],
                owner: %OwnerRef{
                  schema_version: 1,
                  kind: :legacy_plugin,
                  id: ^owner_id
                },
                detail: %{reason: :duplicate_child_spec_diagnostic}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(
                 contributions: [legacy_contribution(owner_id, 1)],
                 compatibility_diagnostics: [child_diagnostic, child_diagnostic]
               ),
               :shadow
             )

    partial = %{child_spec | start_args_sha256: nil}

    assert_diagnostic_error(
      put_in(child_diagnostic.detail.child_spec, partial),
      :invalid_value,
      diagnostic_field_path(["detail", "child_spec"]),
      %{reason: :complete_start_mfa_required}
    )

    target = %Target{
      schema_version: 1,
      kind: :action,
      owner_id: "plugin_one",
      identity: "sample"
    }

    collision = %CompatibilityDiagnostic{
      schema_version: 1,
      code: :collision,
      severity: :error,
      path: [],
      owner: nil,
      detail: %{identity: "sample", participants: [target, target]}
    }

    assert_diagnostic_error(
      collision,
      :duplicate_identity,
      diagnostic_field_path(["detail", "participants"]),
      %{identity: "action:plugin_one:sample"}
    )
  end

  test "non-candidate input returns a typed diagnostic list" do
    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_type,
                path: [],
                owner: nil,
                detail: %{expected: "Candidate", actual: "atom"}
              }
            ]} = Canonical.build_snapshot(:not_a_candidate, :shadow)
  end

  test "compatibility diagnostic details reject invalid values with a stable path" do
    owner = %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "legacy_one"}

    diagnostic = %CompatibilityDiagnostic{
      schema_version: 1,
      code: :legacy_registry,
      severity: :warning,
      path: [],
      owner: owner,
      detail: %{source_lane: :legacy_plugin, legacy_index: 0}
    }

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{
                    schema_version: 1,
                    kind: :field,
                    value: "compatibility_diagnostics"
                  },
                  %PathSegment{schema_version: 1, kind: :index, value: 0},
                  %PathSegment{schema_version: 1, kind: :field, value: "detail"},
                  %PathSegment{schema_version: 1, kind: :field, value: "legacy_index"}
                ],
                owner: ^owner,
                detail: %{reason: :positive_integer_required}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(compatibility_diagnostics: [diagnostic]),
               :shadow
             )
  end

  test "compatibility diagnostics reject unsupported severity" do
    diagnostic = %CompatibilityDiagnostic{
      schema_version: 1,
      code: :legacy_registry,
      severity: :info,
      path: [],
      owner: nil,
      detail: %{source_lane: :legacy_plugin, legacy_index: 1}
    }

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{
                    schema_version: 1,
                    kind: :field,
                    value: "compatibility_diagnostics"
                  },
                  %PathSegment{schema_version: 1, kind: :index, value: 0},
                  %PathSegment{schema_version: 1, kind: :field, value: "severity"}
                ],
                owner: nil,
                detail: %{reason: :unsupported_severity}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(compatibility_diagnostics: [diagnostic]),
               :shadow
             )
  end

  test "compatibility diagnostics reject unsupported evidence codes" do
    diagnostic = %CompatibilityDiagnostic{
      schema_version: 1,
      code: :other,
      severity: :warning,
      path: [],
      owner: nil,
      detail: %{}
    }

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{
                    schema_version: 1,
                    kind: :field,
                    value: "compatibility_diagnostics"
                  },
                  %PathSegment{schema_version: 1, kind: :index, value: 0},
                  %PathSegment{schema_version: 1, kind: :field, value: "code"}
                ],
                owner: nil,
                detail: %{reason: :unsupported_code}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(compatibility_diagnostics: [diagnostic]),
               :shadow
             )
  end

  test "snapshot_bytes rejects a digest that does not reproduce from canonical bytes" do
    assert {:ok, snapshot} = Canonical.build_snapshot(candidate([]), :shadow)
    actual = String.duplicate("0", 64)
    snapshot = %{snapshot | behavior_digest: actual}

    expected =
      :sha256
      |> :crypto.hash(
        "allbert.pack.snapshot.v1\0" <>
          ~s({"compatibility_aliases":[],"compatibility_diagnostics":[],"contributions":[],"effective_actions":[],"schema_version":1})
      )
      |> Base.encode16(case: :lower)

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :digest_mismatch,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "behavior_digest"}
                ],
                owner: nil,
                detail: %{expected: ^expected, actual: ^actual}
              }
            ]} = Canonical.snapshot_bytes(snapshot)
  end

  test "rows and effective actions use typed canonical projections" do
    row = action_row("plugin_one", "sample", 4)
    binding_sha256 = row.payload["binding_sha256"]

    contribution =
      "plugin_one"
      |> legacy_contribution(1)
      |> put_in([Access.key!(:callbacks), Access.key!(:actions)], [row])

    binding = action_binding("sample", 4, "plugin_one")

    assert {:ok, snapshot} =
             Canonical.build_snapshot(
               candidate(contributions: [contribution], action_bindings: [binding]),
               :shadow
             )

    assert {:ok, bytes} = Canonical.snapshot_bytes(snapshot)

    assert bytes =~
             ~s("actions":[{"identity":{"namespace":"action_name","value":"sample"},"kind":"actions","m0_payload_sha256":"#{binding.m0_row_sha256}","order":{"namespace":"legacy_index","value":4},"owner_id":"plugin_one","payload":{"binding_sha256":"#{binding_sha256}","module":"AllbertAssist.Pack.CanonicalTest","name":"sample","registry_order":null},"payload_schema":"action_ref_v1","schema_version":1,"source_authority":{"input_schema_sha256":"#{String.duplicate("b", 64)}","kind":"action","module":"AllbertAssist.Pack.CanonicalTest","name":"sample","normalized_capability":{"app_id":null,"confirmation":"always","execution_mode":"sync","exposure":"agent","notes":null,"permission":"execute","plugin_id":"plugin_one","resumable?":false,"retry_safety":"safe","skill_backed?":true},"output_schema_sha256":"#{String.duplicate("c", 64)}"}}])

    assert bytes =~
             ~s("effective_actions":[{"input_schema_sha256":"#{String.duplicate("b", 64)}","legacy_index":4,"m0_row_sha256":"#{binding.m0_row_sha256}","module":"AllbertAssist.Pack.CanonicalTest","name":"sample","normalized_capability":{"app_id":null,"confirmation":"always","execution_mode":"sync","exposure":"agent","notes":null,"permission":"execute","plugin_id":"plugin_one","resumable?":false,"retry_safety":"safe","skill_backed?":true},"output_schema_sha256":"#{String.duplicate("c", 64)}","registry_order":null,"schema_version":1,"source_lane":"legacy_plugin"}])
  end

  test "finite row-authority floats have the same canonical bytes as RowSchemas" do
    row = settings_row_with_float("plugin_one", "sample", 2)

    contribution =
      "plugin_one"
      |> legacy_contribution(1)
      |> put_in([Access.key!(:callbacks), Access.key!(:settings_fragments)], [row])

    assert {:ok, snapshot} =
             Canonical.build_snapshot(candidate(contributions: [contribution]), :shadow)

    assert {:ok, bytes} = Canonical.snapshot_bytes(snapshot)
    assert bytes =~ ~s("default":1.5)
    assert bytes =~ ~s("min":0.5)

    assert snapshot.behavior_digest ==
             digest("allbert.pack.snapshot.v1\0" <> bytes)
  end

  test "row identities are unique within owner callback and identity namespace" do
    row = skill_root_row("plugin_one", "sample")

    contribution =
      "plugin_one"
      |> legacy_contribution(1)
      |> put_in([Access.key!(:callbacks), Access.key!(:skill_roots)], [row, row])

    owner = %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "plugin_one"}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :duplicate_identity,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "plugin_one"},
                  %PathSegment{schema_version: 1, kind: :field, value: "callbacks"},
                  %PathSegment{schema_version: 1, kind: :field, value: "skill_roots"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "sample"}
                ],
                owner: ^owner,
                detail: %{identity: "plugin_one:skill_roots:root_id:sample"}
              }
            ]} = Canonical.build_snapshot(candidate(contributions: [contribution]), :shadow)
  end

  test "non-alias row order tokens are unique within callback and namespace" do
    first = settings_row_with_float("plugin_one", "first", 2)
    second = settings_row_with_float("plugin_one", "second", 2)

    contribution =
      "plugin_one"
      |> legacy_contribution(1)
      |> put_in(
        [Access.key!(:callbacks), Access.key!(:settings_fragments)],
        [second, first]
      )

    owner = %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "plugin_one"}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :duplicate_order,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "plugin_one"},
                  %PathSegment{schema_version: 1, kind: :field, value: "callbacks"},
                  %PathSegment{schema_version: 1, kind: :field, value: "settings_fragments"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "second"}
                ],
                owner: ^owner,
                detail: %{identity: "settings_fragments:legacy_index:2"}
              }
            ]} = Canonical.build_snapshot(candidate(contributions: [contribution]), :shadow)
  end

  test "row ownership rejection identifies its contribution and callback row" do
    payload = %{
      "root_id" => "sample",
      "relative_path" => "skills/sample",
      "trust_policy" => "trusted",
      "projection_sha256" => String.duplicate("0", 64)
    }

    projection_sha256 =
      RowSchemas.reference_digest_for!(
        :skill_root_v1,
        %Input{payload: payload, source_authority: %{}}
      )

    row = %Row{
      schema_version: 1,
      kind: :skill_roots,
      owner_id: "other_plugin",
      identity: %{namespace: :root_id, value: "sample"},
      order: %{namespace: :lexical, value: "sample"},
      payload_schema: :skill_root_v1,
      payload: Map.put(payload, "projection_sha256", projection_sha256),
      source_authority: %{},
      m0_payload_sha256: nil
    }

    contribution =
      "plugin_one"
      |> legacy_contribution(1)
      |> put_in([Access.key!(:callbacks), Access.key!(:skill_roots)], [row])

    owner = %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "plugin_one"}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :owner_mismatch,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "plugin_one"},
                  %PathSegment{schema_version: 1, kind: :field, value: "callbacks"},
                  %PathSegment{schema_version: 1, kind: :field, value: "skill_roots"},
                  %PathSegment{schema_version: 1, kind: :index, value: 0},
                  %PathSegment{schema_version: 1, kind: :field, value: "owner_id"}
                ],
                owner: ^owner,
                detail: %{expected: "plugin_one", actual: "other_plugin"}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(contributions: [contribution]),
               :shadow
             )
  end

  test "an effective action without one matching declaration row rejects" do
    binding = action_binding("orphaned", 9, "plugin_one")

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "orphaned"}
                ],
                owner: nil,
                detail: %{reason: :missing_action_declaration}
              }
            ]} =
             Canonical.build_snapshot(candidate(action_bindings: [binding]), :shadow)
  end

  test "a non-alias action declaration without an effective binding rejects" do
    row = action_row("plugin_one", "orphaned", 9)

    contribution =
      "plugin_one"
      |> legacy_contribution(1)
      |> put_in([Access.key!(:callbacks), Access.key!(:actions)], [row])

    owner = %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "plugin_one"}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "plugin_one"},
                  %PathSegment{schema_version: 1, kind: :field, value: "callbacks"},
                  %PathSegment{schema_version: 1, kind: :field, value: "actions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "orphaned"}
                ],
                owner: ^owner,
                detail: %{reason: :missing_effective_binding}
              }
            ]} = Canonical.build_snapshot(candidate(contributions: [contribution]), :shadow)
  end

  test "effective action lanes require the matching contribution owner kind" do
    native_binding =
      action_binding("native_action", 4, "legacy_owner")
      |> Map.put(:source_lane, :native_static)
      |> with_m0_digest()

    native_row = %{
      action_row("legacy_owner", "native_action", 4)
      | m0_payload_sha256: native_binding.m0_row_sha256
    }

    legacy_owner =
      "legacy_owner"
      |> legacy_contribution(1)
      |> put_in([Access.key!(:callbacks), Access.key!(:actions)], [native_row])

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "legacy_owner"},
                  %PathSegment{schema_version: 1, kind: :field, value: "callbacks"},
                  %PathSegment{schema_version: 1, kind: :field, value: "actions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "native_action"}
                ],
                owner: %OwnerRef{
                  schema_version: 1,
                  kind: :legacy_plugin,
                  id: "legacy_owner"
                },
                detail: %{reason: :native_action_requires_compiled_owner}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(
                 contributions: [legacy_owner],
                 action_bindings: [native_binding]
               ),
               :shadow
             )

    plugin_row = action_row("declared_owner", "plugin_action", 5)

    declared_owner =
      "declared_owner"
      |> declared_contribution()
      |> put_in([Access.key!(:callbacks), Access.key!(:actions)], [plugin_row])

    plugin_binding = action_binding("plugin_action", 5, "declared_owner")

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "declared_owner"},
                  %PathSegment{schema_version: 1, kind: :field, value: "callbacks"},
                  %PathSegment{schema_version: 1, kind: :field, value: "actions"}
                ],
                owner: %OwnerRef{
                  schema_version: 1,
                  kind: :declared_pack,
                  id: "declared_owner"
                },
                detail: %{reason: :declared_callback_not_data_only}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(
                 contributions: [declared_owner],
                 action_bindings: [plugin_binding]
               ),
               :shadow
             )
  end

  test "effective action bindings must equal their declaration authority" do
    row = action_row("plugin_one", "sample", 4)

    contribution =
      "plugin_one"
      |> legacy_contribution(1)
      |> put_in([Access.key!(:callbacks), Access.key!(:actions)], [row])

    binding =
      action_binding("sample", 4, "plugin_one")
      |> put_in([Access.key!(:normalized_capability), Access.key!(:notes)], "changed")
      |> with_m0_digest()

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "sample"}
                ],
                owner: nil,
                detail: %{reason: :missing_action_declaration}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(contributions: [contribution], action_bindings: [binding]),
               :shadow
             )
  end

  test "a typed action alias binds one source declaration to one effective target" do
    {candidate, compatibility_alias} = action_alias_candidate()

    assert {:ok, snapshot} = Canonical.build_snapshot(candidate, :shadow)

    assert [^compatibility_alias] = snapshot.compatibility_aliases
    assert {:ok, bytes} = Canonical.snapshot_bytes(snapshot)

    assert bytes =~
             ~s("compatibility_aliases":[{"authority_sha256":"#{compatibility_alias.authority_sha256}","kind":"legacy_plugin","module":"AllbertAssist.Pack.CanonicalTest","owner_id":"source_plugin","schema_version":1,"target":{"identity":"sample","kind":"action","owner_id":"target_plugin","schema_version":1}}])
  end

  test "action alias source rows require an enabled legacy-plugin contribution" do
    {candidate, compatibility_alias} = action_alias_candidate()

    source =
      Enum.find(candidate.contributions, fn contribution ->
        contribution.owner.id == "source_plugin"
      end)

    target =
      Enum.find(candidate.contributions, fn contribution ->
        contribution.owner.id == "target_plugin"
      end)

    [source_row] = source.callbacks.actions

    declared =
      "source_plugin"
      |> declared_contribution()
      |> put_in([Access.key!(:callbacks), Access.key!(:actions)], [source_row])

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "source_plugin"},
                  %PathSegment{schema_version: 1, kind: :field, value: "callbacks"},
                  %PathSegment{schema_version: 1, kind: :field, value: "actions"}
                ],
                owner: %OwnerRef{
                  schema_version: 1,
                  kind: :declared_pack,
                  id: "source_plugin"
                },
                detail: %{reason: :declared_callback_not_data_only}
              }
            ]} =
             Canonical.build_snapshot(
               %{candidate | contributions: [declared, target]},
               :shadow
             )

    compiled_owner_id = "allbert_kernel"
    compiled_row = %{source_row | owner_id: compiled_owner_id}

    compiled =
      compiled_contribution()
      |> put_in([Access.key!(:callbacks), Access.key!(:actions)], [compiled_row])

    compiled_alias = %{compatibility_alias | owner_id: compiled_owner_id}

    assert_action_alias_source_owner_error(
      %{
        candidate
        | contributions: [compiled, target],
          compatibility_aliases: [compiled_alias]
      },
      compiled_alias,
      :compiled_pack,
      compiled_owner_id
    )
  end

  test "an action alias source row requires exactly one top-level alias" do
    {candidate, _compatibility_alias} = action_alias_candidate()
    candidate = %{candidate | compatibility_aliases: []}
    owner = %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "source_plugin"}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "source_plugin"},
                  %PathSegment{schema_version: 1, kind: :field, value: "callbacks"},
                  %PathSegment{schema_version: 1, kind: :field, value: "actions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "sample"}
                ],
                owner: ^owner,
                detail: %{reason: :missing_compatibility_alias}
              }
            ]} = Canonical.build_snapshot(candidate, :shadow)
  end

  test "alias targets and alias kinds are closed" do
    {candidate, compatibility_alias} = action_alias_candidate()

    invalid_target = %{compatibility_alias.target | kind: :other}
    invalid_alias = %{compatibility_alias | target: invalid_target}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "compatibility_aliases"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "source_plugin"},
                  %PathSegment{schema_version: 1, kind: :field, value: "target"},
                  %PathSegment{schema_version: 1, kind: :field, value: "kind"}
                ],
                owner: nil,
                detail: %{reason: :unsupported_target_kind}
              }
            ]} =
             Canonical.build_snapshot(
               %{candidate | compatibility_aliases: [invalid_alias]},
               :shadow
             )

    wrong_kind = %{compatibility_alias | kind: :deprecated_alias}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "compatibility_aliases"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "source_plugin"},
                  %PathSegment{schema_version: 1, kind: :field, value: "kind"}
                ],
                owner: nil,
                detail: %{reason: :alias_kind_target_mismatch}
              }
            ]} =
             Canonical.build_snapshot(%{candidate | compatibility_aliases: [wrong_kind]}, :shadow)
  end

  test "an action alias rejects authority bytes that do not reproduce" do
    {candidate, compatibility_alias} = action_alias_candidate()
    actual = String.duplicate("0", 64)
    invalid_alias = %{compatibility_alias | authority_sha256: actual}
    candidate = %{candidate | compatibility_aliases: [invalid_alias]}

    owner = %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "source_plugin"}
    expected = compatibility_alias.authority_sha256

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :digest_mismatch,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "compatibility_aliases"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "source_plugin"},
                  %PathSegment{schema_version: 1, kind: :field, value: "authority_sha256"}
                ],
                owner: ^owner,
                detail: %{expected: ^expected, actual: ^actual}
              }
            ]} = Canonical.build_snapshot(candidate, :shadow)
  end

  test "a second top-level alias for the same source and target rejects" do
    {candidate, compatibility_alias} = action_alias_candidate()
    candidate = %{candidate | compatibility_aliases: [compatibility_alias, compatibility_alias]}
    owner = %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "source_plugin"}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :duplicate_identity,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "compatibility_aliases"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "source_plugin"}
                ],
                owner: ^owner,
                detail: %{
                  identity: "legacy_plugin:source_plugin:action:target_plugin:sample"
                }
              }
            ]} = Canonical.build_snapshot(candidate, :shadow)
  end

  test "a deprecated contribution alias binds owner-neutral callback authority" do
    {candidate, compatibility_alias} = contribution_alias_candidate()

    assert {:ok, snapshot} = Canonical.build_snapshot(candidate, :shadow)
    assert [^compatibility_alias] = snapshot.compatibility_aliases
    assert {:ok, bytes} = Canonical.snapshot_bytes(snapshot)

    assert bytes =~
             ~s("compatibility_aliases":[{"authority_sha256":"#{compatibility_alias.authority_sha256}","kind":"deprecated_alias","module":"AllbertAssist.Pack.CanonicalTest","owner_id":"source_plugin","schema_version":1,"target":{"identity":"target_plugin","kind":"contribution","owner_id":"target_plugin","schema_version":1}}])
  end

  test "a contribution alias rejects a semantic target change" do
    {candidate, compatibility_alias} = contribution_alias_candidate()

    contributions =
      Enum.map(candidate.contributions, fn
        %Contribution{owner: %Owner{id: "target_plugin"}} = contribution ->
          put_in(contribution.compatibility.trust, :untrusted)

        contribution ->
          contribution
      end)

    candidate = %{candidate | contributions: contributions}
    owner = %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "source_plugin"}
    target = compatibility_alias.target

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :alias_mismatch,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "compatibility_aliases"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "source_plugin"}
                ],
                owner: ^owner,
                detail: %{
                  owner_id: "source_plugin",
                  target: ^target
                }
              }
            ]} = Canonical.build_snapshot(candidate, :shadow)
  end

  test "a contribution alias digest binds the explicit source-to-target carrier transition" do
    {candidate, compatibility_alias} = contribution_alias_candidate()

    contributions =
      Enum.map(candidate.contributions, fn
        %Contribution{owner: %Owner{id: "target_plugin"}} = contribution ->
          %{contribution | implementation_module: AllbertAssist.Pack.RowSchemas}

        contribution ->
          contribution
      end)

    owner = %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "source_plugin"}
    target = compatibility_alias.target

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :digest_mismatch,
                owner: ^owner,
                detail: %{actual: _, expected: _}
              }
            ]} =
             Canonical.build_snapshot(%{candidate | contributions: contributions}, :shadow)

    assert target.owner_id == "target_plugin"
  end

  test "a deprecated contribution requires exactly one top-level alias" do
    {candidate, compatibility_alias} = contribution_alias_candidate()
    candidate = %{candidate | compatibility_aliases: []}
    owner = %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "source_plugin"}
    target = compatibility_alias.target

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :alias_mismatch,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "source_plugin"},
                  %PathSegment{schema_version: 1, kind: :field, value: "compatibility"},
                  %PathSegment{schema_version: 1, kind: :field, value: "alias_of"}
                ],
                owner: ^owner,
                detail: %{owner_id: "source_plugin", target: ^target}
              }
            ]} = Canonical.build_snapshot(candidate, :shadow)
  end

  test "compiled legacy-provenance actions require the exact deprecated contribution target" do
    {candidate, _compatibility_alias} = compiled_legacy_action_candidate()

    assert {:ok, _snapshot} = Canonical.build_snapshot(candidate, :shadow)

    without_alias = %{
      candidate
      | contributions: Enum.reject(candidate.contributions, &(&1.owner.id == "source_plugin")),
        compatibility_aliases: []
    }

    assert {:error, [%{detail: %{reason: :legacy_action_requires_deprecated_pack_alias}}]} =
             Canonical.build_snapshot(without_alias, :shadow)

    other_target = compiled_contribution("other_pack", :other_pack, 1)

    other_ref = %Target{
      schema_version: 1,
      kind: :contribution,
      owner_id: "other_pack",
      identity: "other_pack"
    }

    retargeted_source =
      candidate.contributions
      |> Enum.find(&(&1.owner.id == "source_plugin"))
      |> put_in([Access.key!(:compatibility), Access.key!(:alias_of)], other_ref)

    {:ok, authority} =
      Canonical.contribution_alias_authority(retargeted_source, other_target)

    retargeted_alias = %CompatibilityAlias{
      schema_version: 1,
      kind: :deprecated_alias,
      owner_id: "source_plugin",
      target: other_ref,
      module: __MODULE__,
      authority_sha256: authority.authority_sha256
    }

    retargeted = %{
      candidate
      | contributions:
          Enum.map(candidate.contributions, fn
            %Contribution{owner: %Owner{id: "source_plugin"}} -> retargeted_source
            contribution -> contribution
          end) ++ [other_target],
        compatibility_aliases: [retargeted_alias]
    }

    assert {:error, [%{detail: %{reason: :legacy_action_requires_deprecated_pack_alias}}]} =
             Canonical.build_snapshot(retargeted, :shadow)
  end

  test "effective action records validate their exact scalar contract before traversal" do
    binding = action_binding("sample", 4, "plugin_one")

    assert_action_error(
      Map.delete(binding, :name),
      :missing_field,
      [
        %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
        %PathSegment{schema_version: 1, kind: :index, value: 0},
        %PathSegment{schema_version: 1, kind: :field, value: "name"}
      ],
      %{field: "name"}
    )

    cases = [
      {%{binding | schema_version: 2}, ["schema_version"], :unsupported_schema_version,
       %{expected: 1, actual: 2}},
      {%{binding | module: nil}, ["module"], :invalid_value, %{reason: :module_required}},
      {%{binding | name: " sample"}, ["name"], :invalid_value,
       %{reason: :canonical_string_required}},
      {%{binding | source_lane: :other}, ["source_lane"], :invalid_value,
       %{reason: :unsupported_source_lane}},
      {%{binding | legacy_index: 0}, ["legacy_index"], :invalid_value,
       %{reason: :positive_integer_required}},
      {%{binding | registry_order: -1}, ["registry_order"], :invalid_value,
       %{reason: :non_neg_integer_or_nil_required}}
    ]

    for {invalid, fields, code, detail} <- cases do
      identity = if fields == ["name"], do: invalid.name, else: "sample"

      path =
        [
          %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
          %PathSegment{schema_version: 1, kind: :identity, value: identity}
        ] ++ Enum.map(fields, &%PathSegment{schema_version: 1, kind: :field, value: &1})

      assert_action_error(invalid, code, path, detail)
    end
  end

  test "effective action identities modules and order tokens reject duplicates" do
    first = action_binding("same", 4, "plugin_one")
    second = action_binding("same", 5, "plugin_two")

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :duplicate_identity,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "same"}
                ],
                detail: %{identity: "same"}
              }
            ]} = Canonical.build_snapshot(candidate(action_bindings: [second, first]), :shadow)

    first = action_binding("first", 4, "plugin_one")
    second = action_binding("second", 5, "plugin_two")

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :duplicate_identity,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "second"},
                  %PathSegment{schema_version: 1, kind: :field, value: "module"}
                ],
                detail: %{identity: "AllbertAssist.Pack.CanonicalTest"}
              }
            ]} = Canonical.build_snapshot(candidate(action_bindings: [second, first]), :shadow)

    first = %{action_binding("first", 4, "plugin_one") | module: Canonical}
    second = %{action_binding("second", 4, "plugin_two") | module: Registry}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :duplicate_order,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "second"}
                ],
                detail: %{identity: "legacy_index:4"}
              }
            ]} = Canonical.build_snapshot(candidate(action_bindings: [second, first]), :shadow)

    first = %{first | registry_order: 10}
    second = %{second | registry_order: 11}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :duplicate_order,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "second"}
                ],
                detail: %{identity: "legacy_index:4"}
              }
            ]} = Canonical.build_snapshot(candidate(action_bindings: [second, first]), :shadow)

    first = %{first | legacy_index: 4, registry_order: 10}
    second = %{second | legacy_index: 5, registry_order: 10}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :duplicate_order,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "second"}
                ],
                detail: %{identity: "registry_order:10"}
              }
            ]} = Canonical.build_snapshot(candidate(action_bindings: [second, first]), :shadow)
  end

  test "effective action evidence digests must be lowercase SHA-256" do
    binding = %{action_binding("sample", 4, "plugin_one") | m0_row_sha256: "ABC"}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "sample"},
                  %PathSegment{schema_version: 1, kind: :field, value: "m0_row_sha256"}
                ],
                owner: nil,
                detail: %{reason: :lowercase_sha256_required}
              }
            ]} = Canonical.build_snapshot(candidate(action_bindings: [binding]), :shadow)
  end

  test "effective action M0 evidence is recomputed rather than trusted from both carriers" do
    valid_binding = action_binding("sample", 4, "plugin_one")
    expected = valid_binding.m0_row_sha256
    actual = String.duplicate("f", 64)
    refute actual == expected

    binding = %{valid_binding | m0_row_sha256: actual}
    row = %{action_row("plugin_one", "sample", 4) | m0_payload_sha256: actual}

    contribution =
      "plugin_one"
      |> legacy_contribution(1)
      |> put_in([Access.key!(:callbacks), Access.key!(:actions)], [row])

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :digest_mismatch,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "sample"},
                  %PathSegment{schema_version: 1, kind: :field, value: "m0_row_sha256"}
                ],
                owner: nil,
                detail: %{expected: ^expected, actual: ^actual}
              }
            ]} =
             Canonical.build_snapshot(
               candidate(contributions: [contribution], action_bindings: [binding]),
               :shadow
             )
  end

  test "effective action capability maps reject unknown fields" do
    binding = action_binding("sample", 4, "plugin_one")

    binding = %{
      binding
      | normalized_capability: Map.put(binding.normalized_capability, :unexpected, true)
    }

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :unknown_field,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                  %PathSegment{schema_version: 1, kind: :identity, value: "sample"},
                  %PathSegment{
                    schema_version: 1,
                    kind: :field,
                    value: "normalized_capability"
                  },
                  %PathSegment{schema_version: 1, kind: :field, value: "unexpected"}
                ],
                owner: nil,
                detail: %{field: "unexpected"}
              }
            ]} = Canonical.build_snapshot(candidate(action_bindings: [binding]), :shadow)
  end

  test "every effective action capability value retains its exact scalar type" do
    cases = [
      {:app_id, "bad", "atom_or_nil", "string"},
      {:confirmation, [], "atom_or_nil", "list"},
      {:execution_mode, "sync", "atom", "string"},
      {:exposure, :other, "agent_or_internal", "atom"},
      {:notes, :bad, "string_or_nil", "atom"},
      {:permission, nil, "atom", "atom"},
      {:plugin_id, :bad, "string_or_nil", "atom"},
      {:resumable?, :yes, "boolean", "atom"},
      {:retry_safety, "safe", "atom", "string"},
      {:skill_backed?, nil, "boolean", "atom"}
    ]

    for {field, value, expected, actual} <- cases do
      binding = action_binding("sample", 4, "plugin_one")

      binding = %{
        binding
        | normalized_capability: Map.put(binding.normalized_capability, field, value)
      }

      field_name = Atom.to_string(field)

      assert {:error,
              [
                %ValidationDiagnostic{
                  schema_version: 1,
                  code: :invalid_type,
                  path: [
                    %PathSegment{schema_version: 1, kind: :field, value: "action_bindings"},
                    %PathSegment{schema_version: 1, kind: :identity, value: "sample"},
                    %PathSegment{
                      schema_version: 1,
                      kind: :field,
                      value: "normalized_capability"
                    },
                    %PathSegment{schema_version: 1, kind: :field, value: ^field_name}
                  ],
                  owner: nil,
                  detail: %{expected: ^expected, actual: ^actual}
                }
              ]} = Canonical.build_snapshot(candidate(action_bindings: [binding]), :shadow)
    end
  end

  test "snapshot_bytes validates publication even though publication is not digested" do
    assert {:ok, snapshot} = Canonical.build_snapshot(candidate([]), :shadow)
    snapshot = %{snapshot | publication: :draft}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_value,
                path: [%PathSegment{schema_version: 1, kind: :field, value: "publication"}],
                owner: nil,
                detail: %{reason: :unsupported_publication}
              }
            ]} = Canonical.snapshot_bytes(snapshot)
  end

  test "snapshot collections validate with snapshot field names" do
    assert {:ok, snapshot} = Canonical.build_snapshot(candidate([]), :shadow)
    snapshot = %{snapshot | effective_actions: :not_a_list}

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :invalid_type,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "effective_actions"}
                ],
                owner: nil,
                detail: %{expected: "list", actual: "atom"}
              }
            ]} = Canonical.snapshot_bytes(snapshot)
  end

  defp candidate(overrides) do
    struct!(
      Candidate,
      [
        schema_version: 1,
        contributions: [],
        action_bindings: [],
        compatibility_aliases: [],
        compatibility_diagnostics: []
      ] ++ overrides
    )
  end

  defp legacy_contribution(id, order) do
    %Contribution{
      schema_version: 1,
      owner: %Owner{schema_version: 1, kind: :legacy_plugin, id: id, application: nil},
      descriptor: nil,
      implementation_module: __MODULE__,
      source_lane: :legacy_plugin,
      owner_order: %Order{schema_version: 1, namespace: :legacy_plugin, value: order},
      compatibility: %Compatibility{
        schema_version: 1,
        kind: :legacy_plugin,
        legacy_id: id,
        alias_of: nil,
        trust: :pending,
        enabled: true
      },
      callbacks: empty_callbacks()
    }
  end

  defp disabled_legacy_contribution(id, order) do
    put_in(legacy_contribution(id, order).compatibility.enabled, false)
  end

  defp disabled_plugin_diagnostic(id, kind \\ :legacy_plugin) do
    %CompatibilityDiagnostic{
      schema_version: 1,
      code: :disabled_plugin,
      severity: :warning,
      path: [
        %PathSegment{schema_version: 1, kind: :field, value: "plugins"},
        %PathSegment{schema_version: 1, kind: :identity, value: id},
        %PathSegment{schema_version: 1, kind: :field, value: "status"}
      ],
      owner: %OwnerRef{schema_version: 1, kind: kind, id: id},
      detail: %{source: :test, status: :disabled}
    }
  end

  defp declared_contribution(id) do
    %Contribution{
      schema_version: 1,
      owner: %Owner{
        schema_version: 1,
        kind: :declared_pack,
        id: id,
        application: nil
      },
      implementation_module: nil,
      descriptor: nil,
      source_lane: :declared,
      owner_order: %Order{schema_version: 1, namespace: :declared_pack, value: id},
      compatibility: %Compatibility{
        schema_version: 1,
        kind: :declared,
        legacy_id: nil,
        alias_of: nil,
        trust: :pending,
        enabled: true
      },
      callbacks: empty_callbacks()
    }
  end

  defp assert_contribution_error(contribution, code, path, detail) do
    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: ^code,
                path: ^path,
                detail: ^detail
              }
            ]} = Canonical.build_snapshot(candidate(contributions: [contribution]), :shadow)
  end

  defp assert_action_error(action, code, path, detail) do
    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: ^code,
                path: ^path,
                detail: ^detail
              }
            ]} = Canonical.build_snapshot(candidate(action_bindings: [action]), :shadow)
  end

  defp assert_diagnostic_error(diagnostic, code, path, detail) do
    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: ^code,
                path: ^path,
                detail: ^detail
              }
            ]} =
             Canonical.build_snapshot(
               candidate(compatibility_diagnostics: [diagnostic]),
               :shadow
             )
  end

  defp assert_action_alias_source_owner_error(candidate, compatibility_alias, kind, owner_id) do
    target = compatibility_alias.target

    assert {:error,
            [
              %ValidationDiagnostic{
                schema_version: 1,
                code: :alias_mismatch,
                path: [
                  %PathSegment{schema_version: 1, kind: :field, value: "compatibility_aliases"},
                  %PathSegment{schema_version: 1, kind: :identity, value: ^owner_id}
                ],
                owner: %OwnerRef{
                  schema_version: 1,
                  kind: ^kind,
                  id: ^owner_id
                },
                detail: %{owner_id: ^owner_id, target: ^target}
              }
            ]} = Canonical.build_snapshot(candidate, :shadow)
  end

  defp legacy_diagnostic do
    %CompatibilityDiagnostic{
      schema_version: 1,
      code: :legacy_registry,
      severity: :warning,
      path: [%PathSegment{schema_version: 1, kind: :field, value: "plugins"}],
      owner: %OwnerRef{schema_version: 1, kind: :legacy_plugin, id: "legacy_one"},
      detail: %{source_lane: :legacy_plugin, legacy_index: 1}
    }
  end

  defp diagnostic_field_path(fields) do
    [
      %PathSegment{schema_version: 1, kind: :field, value: "compatibility_diagnostics"},
      %PathSegment{schema_version: 1, kind: :index, value: 0}
    ] ++ Enum.map(fields, &%PathSegment{schema_version: 1, kind: :field, value: &1})
  end

  defp contribution_field_path(owner_id, fields) do
    [
      %PathSegment{schema_version: 1, kind: :field, value: "contributions"},
      %PathSegment{schema_version: 1, kind: :identity, value: owner_id}
    ] ++ Enum.map(fields, &%PathSegment{schema_version: 1, kind: :field, value: &1})
  end

  defp compiled_contribution do
    compiled_contribution("allbert_kernel", :allbert_kernel, 0, :kernel)
  end

  defp compiled_contribution(id, application, order) do
    compiled_contribution(id, application, order, :native)
  end

  defp compiled_contribution(id, application, order, tier) do
    %Contribution{
      schema_version: 1,
      owner: %Owner{
        schema_version: 1,
        kind: :compiled_pack,
        id: id,
        application: application
      },
      descriptor: %Descriptor{
        schema_version: 1,
        id: id,
        application: application,
        application_version: "1.4.0",
        capability_tier: tier,
        provenance: %{
          source: :signed_release,
          component: "beam-#{String.replace(id, "_", "-")}"
        },
        registry_order: order
      },
      implementation_module: __MODULE__,
      source_lane: :native,
      owner_order: %Order{schema_version: 1, namespace: :compiled_pack, value: order},
      compatibility: %Compatibility{
        schema_version: 1,
        kind: :native,
        legacy_id: nil,
        alias_of: nil,
        trust: :trusted,
        enabled: true
      },
      callbacks: empty_callbacks()
    }
  end

  defp empty_callbacks do
    %{
      apps: [],
      actions: [],
      settings_fragments: [],
      settings_migrations: [],
      channels: [],
      surfaces: [],
      skill_roots: [],
      home_roots: [],
      jobs: [],
      stores: [],
      prompt_rules: [],
      intent_descriptors: [],
      cli_groups: [],
      release_assets: [],
      test_lanes: []
    }
  end

  defp action_binding(name, legacy_index, plugin_id) do
    with_m0_digest(%ActionBinding{
      schema_version: 1,
      module: __MODULE__,
      name: name,
      source_lane: :legacy_plugin,
      legacy_index: legacy_index,
      registry_order: nil,
      normalized_capability: %{
        app_id: nil,
        confirmation: :always,
        execution_mode: :sync,
        exposure: :agent,
        notes: nil,
        permission: :execute,
        plugin_id: plugin_id,
        resumable?: false,
        retry_safety: :safe,
        skill_backed?: true
      },
      m0_row_sha256: String.duplicate("0", 64),
      input_schema_sha256: String.duplicate("b", 64),
      output_schema_sha256: String.duplicate("c", 64)
    })
  end

  defp with_m0_digest(%ActionBinding{} = binding),
    do: %{binding | m0_row_sha256: m0_action_digest(binding)}

  defp m0_action_digest(%ActionBinding{} = binding) do
    capability = binding.normalized_capability

    projection = %{
      "index" => binding.legacy_index,
      "name" => binding.name,
      "module" => m0_atom_value(binding.module),
      "source_bucket" =>
        if(binding.source_lane == :native_static, do: "static", else: "plugin_append"),
      "capability" => %{
        "app_id" => m0_atom_value(capability.app_id),
        "confirmation" => m0_atom_value(capability.confirmation),
        "execution_mode" => m0_atom_value(capability.execution_mode),
        "exposure" => m0_atom_value(capability.exposure),
        "notes" => capability.notes,
        "permission" => m0_atom_value(capability.permission),
        "plugin_id" => capability.plugin_id,
        "resumable?" => capability.resumable?,
        "retry_safety" => m0_atom_value(capability.retry_safety),
        "skill_backed?" => capability.skill_backed?
      },
      "input_schema_sha256" => binding.input_schema_sha256,
      "output_schema_sha256" => binding.output_schema_sha256
    }

    projection
    |> canonical_json!()
    |> digest()
  end

  defp m0_atom_value(nil), do: nil

  defp m0_atom_value(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp canonical_json!(value) when is_map(value) do
    encoded =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, nested} ->
        json_scalar!(key) <> ":" <> canonical_json!(nested)
      end)

    "{" <> encoded <> "}"
  end

  defp canonical_json!(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json!/1) <> "]"

  defp canonical_json!(nil), do: "null"
  defp canonical_json!(value), do: json_scalar!(value)

  defp json_scalar!(value), do: value |> :json.encode() |> IO.iodata_to_binary()

  defp action_row(owner_id, name, legacy_index, plugin_id \\ nil) do
    binding = action_binding(name, legacy_index, plugin_id || owner_id)

    source_authority = %{
      "kind" => "action",
      "module" => __MODULE__,
      "name" => name,
      "normalized_capability" => binding.normalized_capability,
      "input_schema_sha256" => String.duplicate("b", 64),
      "output_schema_sha256" => String.duplicate("c", 64)
    }

    payload = %{
      "module" => __MODULE__,
      "name" => name,
      "registry_order" => nil,
      "binding_sha256" => String.duplicate("0", 64)
    }

    binding_sha256 =
      RowSchemas.reference_digest_for!(
        :action_ref_v1,
        %Input{payload: payload, source_authority: source_authority}
      )

    normalized =
      RowSchemas.normalize!(
        :action_ref_v1,
        %Input{
          payload: Map.put(payload, "binding_sha256", binding_sha256),
          source_authority: source_authority
        }
      )

    %Row{
      schema_version: 1,
      kind: :actions,
      owner_id: owner_id,
      identity: %{namespace: :action_name, value: name},
      order: %{namespace: :legacy_index, value: legacy_index},
      payload_schema: :action_ref_v1,
      payload: RowSchemas.canonical_projection(normalized),
      source_authority: RowSchemas.source_authority_projection(normalized),
      m0_payload_sha256: binding.m0_row_sha256
    }
  end

  defp settings_row_with_float(owner_id, fragment_id, legacy_index) do
    source_authority = %{
      "fragment_id" => fragment_id,
      "legacy_owner_id" => "legacy_settings",
      "source" => "plugin",
      "group" => "sample",
      "schema_version" => 1,
      "schema" => %{
        "sample.value" => %{
          "type" => "number",
          "default" => 1.5,
          "writable?" => true,
          "sensitive?" => false,
          "min" => 0.5
        }
      },
      "defaults" => %{"sample" => %{"value" => 1.5}},
      "safe_write_keys" => ["sample.value"],
      "metadata" => %{}
    }

    payload = %{
      "fragment_id" => fragment_id,
      "owner_id" => owner_id,
      "schema_version" => 1,
      "projection_sha256" => String.duplicate("0", 64)
    }

    projection_sha256 =
      RowSchemas.reference_digest_for!(
        :settings_fragment_ref_v1,
        %Input{payload: payload, source_authority: source_authority}
      )

    normalized =
      RowSchemas.normalize!(
        :settings_fragment_ref_v1,
        %Input{
          payload: Map.put(payload, "projection_sha256", projection_sha256),
          source_authority: source_authority
        }
      )

    %Row{
      schema_version: 1,
      kind: :settings_fragments,
      owner_id: owner_id,
      identity: %{namespace: :fragment_id, value: fragment_id},
      order: %{namespace: :legacy_index, value: legacy_index},
      payload_schema: :settings_fragment_ref_v1,
      payload: RowSchemas.canonical_projection(normalized),
      source_authority: RowSchemas.source_authority_projection(normalized),
      m0_payload_sha256: nil
    }
  end

  defp skill_root_row(owner_id, root_id, relative_path \\ nil, trust_policy \\ "pending") do
    payload = %{
      "root_id" => root_id,
      "relative_path" => relative_path || "skills/#{root_id}",
      "trust_policy" => trust_policy,
      "projection_sha256" => String.duplicate("0", 64)
    }

    projection_sha256 =
      RowSchemas.reference_digest_for!(
        :skill_root_v1,
        %Input{payload: payload, source_authority: %{}}
      )

    normalized =
      RowSchemas.normalize!(
        :skill_root_v1,
        %Input{
          payload: Map.put(payload, "projection_sha256", projection_sha256),
          source_authority: %{}
        }
      )

    %Row{
      schema_version: 1,
      kind: :skill_roots,
      owner_id: owner_id,
      identity: %{namespace: :root_id, value: root_id},
      order: %{namespace: :lexical, value: root_id},
      payload_schema: :skill_root_v1,
      payload: RowSchemas.canonical_projection(normalized),
      source_authority: RowSchemas.source_authority_projection(normalized),
      m0_payload_sha256: nil
    }
  end

  defp alias_authority_sha256(source_authority) do
    bytes =
      ~s({"input_schema_sha256":"#{source_authority["input_schema_sha256"]}","kind":"action","module":"#{source_authority["module"]}","name":"#{source_authority["name"]}","normalized_capability":{"app_id":null,"confirmation":"always","execution_mode":"sync","exposure":"agent","notes":null,"permission":"execute","plugin_id":"#{source_authority["normalized_capability"]["plugin_id"]}","resumable?":false,"retry_safety":"safe","skill_backed?":true},"output_schema_sha256":"#{source_authority["output_schema_sha256"]}"})

    :sha256
    |> :crypto.hash("allbert.pack.alias.authority.v1\0" <> bytes)
    |> Base.encode16(case: :lower)
  end

  defp action_alias_candidate do
    target_row = action_row("target_plugin", "sample", 4)

    source_row = %{
      target_row
      | owner_id: "source_plugin",
        order: %{namespace: :alias_target, value: 4},
        m0_payload_sha256: nil
    }

    target_contribution =
      "target_plugin"
      |> legacy_contribution(1)
      |> put_in([Access.key!(:callbacks), Access.key!(:actions)], [target_row])

    source_contribution =
      "source_plugin"
      |> legacy_contribution(2)
      |> put_in([Access.key!(:callbacks), Access.key!(:actions)], [source_row])

    target = %Target{
      schema_version: 1,
      kind: :action,
      owner_id: "target_plugin",
      identity: "sample"
    }

    compatibility_alias = %CompatibilityAlias{
      schema_version: 1,
      kind: :legacy_plugin,
      owner_id: "source_plugin",
      target: target,
      module: __MODULE__,
      authority_sha256: alias_authority_sha256(target_row.source_authority)
    }

    candidate =
      candidate(
        contributions: [source_contribution, target_contribution],
        action_bindings: [action_binding("sample", 4, "target_plugin")],
        compatibility_aliases: [compatibility_alias]
      )

    {candidate, compatibility_alias}
  end

  defp contribution_alias_candidate do
    target = %Target{
      schema_version: 1,
      kind: :contribution,
      owner_id: "target_plugin",
      identity: "target_plugin"
    }

    target_contribution = legacy_contribution("target_plugin", 1)

    source_contribution =
      "source_plugin"
      |> legacy_contribution(2)
      |> Map.update!(:compatibility, fn compatibility ->
        %{
          compatibility
          | kind: :deprecated_alias,
            legacy_id: "source_plugin",
            alias_of: target
        }
      end)

    {:ok, authority} =
      Canonical.contribution_alias_authority(source_contribution, target_contribution)

    compatibility_alias = %CompatibilityAlias{
      schema_version: 1,
      kind: :deprecated_alias,
      owner_id: "source_plugin",
      target: target,
      module: __MODULE__,
      authority_sha256: authority.authority_sha256
    }

    candidate =
      candidate(
        contributions: [source_contribution, target_contribution],
        compatibility_aliases: [compatibility_alias]
      )

    {candidate, compatibility_alias}
  end

  defp compiled_legacy_action_candidate do
    target_ref = %Target{
      schema_version: 1,
      kind: :contribution,
      owner_id: "target_plugin",
      identity: "target_plugin"
    }

    target_row = action_row("target_plugin", "sample", 4, "source_plugin")

    target_contribution =
      "target_plugin"
      |> then(&compiled_contribution(&1, :target_plugin, 0))
      |> put_in([Access.key!(:callbacks), Access.key!(:actions)], [target_row])

    source_contribution =
      "source_plugin"
      |> legacy_contribution(1)
      |> put_in([Access.key!(:compatibility), Access.key!(:kind)], :deprecated_alias)
      |> put_in([Access.key!(:compatibility), Access.key!(:alias_of)], target_ref)
      |> put_in([Access.key!(:compatibility), Access.key!(:trust)], :trusted)

    {:ok, authority} =
      Canonical.contribution_alias_authority(source_contribution, target_contribution)

    compatibility_alias = %CompatibilityAlias{
      schema_version: 1,
      kind: :deprecated_alias,
      owner_id: "source_plugin",
      target: target_ref,
      module: __MODULE__,
      authority_sha256: authority.authority_sha256
    }

    candidate =
      candidate(
        contributions: [source_contribution, target_contribution],
        action_bindings: [action_binding("sample", 4, "source_plugin")],
        compatibility_aliases: [compatibility_alias]
      )

    {candidate, compatibility_alias}
  end

  defp digest(bytes),
    do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
