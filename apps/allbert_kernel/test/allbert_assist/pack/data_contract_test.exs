defmodule AllbertAssist.Pack.DataContractTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Pack.{
    ActionBinding,
    ChildSpecProjection,
    Compatibility,
    CompatibilityAlias,
    CompatibilityDiagnostic,
    Contribution,
    Order,
    Owner,
    OwnerRef,
    PathSegment,
    Row,
    Target,
    ValidationDiagnostic
  }

  test "contribution contracts require exactly their declared fields" do
    target =
      exact_struct!(Target, %{
        schema_version: 1,
        kind: :contribution,
        owner_id: "legacy",
        identity: "legacy"
      })

    owner =
      exact_struct!(Owner, %{
        schema_version: 1,
        kind: :legacy_plugin,
        id: "legacy",
        application: nil
      })

    order =
      exact_struct!(Order, %{
        schema_version: 1,
        namespace: :legacy_plugin,
        value: 1
      })

    compatibility =
      exact_struct!(Compatibility, %{
        schema_version: 1,
        kind: :deprecated_alias,
        legacy_id: "legacy",
        alias_of: target,
        trust: :trusted,
        enabled: true
      })

    exact_struct!(Contribution, %{
      schema_version: 1,
      owner: owner,
      implementation_module: __MODULE__,
      descriptor: nil,
      source_lane: :legacy_plugin,
      owner_order: order,
      compatibility: compatibility,
      callbacks: callback_rows()
    })
  end

  test "binding and callback-row contracts require exactly their declared fields" do
    exact_struct!(OwnerRef, %{
      schema_version: 1,
      kind: :legacy_plugin,
      id: "legacy"
    })

    exact_struct!(ActionBinding, %{
      schema_version: 1,
      module: __MODULE__,
      name: "data_contract",
      source_lane: :native_static,
      legacy_index: 1,
      registry_order: nil,
      normalized_capability: %{
        app_id: nil,
        confirmation: nil,
        execution_mode: :sync,
        exposure: :internal,
        notes: nil,
        permission: :read_only,
        plugin_id: nil,
        resumable?: false,
        retry_safety: :safe,
        skill_backed?: false
      },
      m0_row_sha256: String.duplicate("0", 64),
      input_schema_sha256: String.duplicate("1", 64),
      output_schema_sha256: String.duplicate("2", 64)
    })

    exact_struct!(Row, %{
      schema_version: 1,
      kind: :actions,
      owner_id: "legacy",
      identity: %{namespace: :action, value: "data_contract"},
      order: %{namespace: :legacy_index, value: 1},
      payload_schema: :action_ref_v1,
      payload: %{
        "module" => "AllbertAssist.Pack.DataContractTest",
        "name" => "data_contract",
        "registry_order" => nil,
        "binding_sha256" => String.duplicate("3", 64)
      },
      source_authority: %{
        "kind" => "action",
        "module" => "AllbertAssist.Pack.DataContractTest",
        "name" => "data_contract",
        "normalized_capability" => %{
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
        },
        "input_schema_sha256" => String.duplicate("4", 64),
        "output_schema_sha256" => String.duplicate("5", 64)
      },
      m0_payload_sha256: nil
    })
  end

  test "compatibility and validation evidence require exactly their declared fields" do
    target =
      exact_struct!(Target, %{
        schema_version: 1,
        kind: :action,
        owner_id: "allbert_assist",
        identity: "data_contract"
      })

    owner =
      exact_struct!(OwnerRef, %{
        schema_version: 1,
        kind: :legacy_plugin,
        id: "legacy"
      })

    path_segment =
      exact_struct!(PathSegment, %{
        schema_version: 1,
        kind: :identity,
        value: "legacy"
      })

    exact_struct!(CompatibilityAlias, %{
      schema_version: 1,
      kind: :legacy_plugin,
      owner_id: "legacy",
      target: target,
      module: __MODULE__,
      authority_sha256: String.duplicate("4", 64)
    })

    exact_struct!(ChildSpecProjection, %{
      schema_version: 1,
      id: "legacy_supervisor",
      start_module: "AllbertAssist.Pack.DataContractTest",
      start_function: "start_link",
      start_arity: 1,
      start_args_sha256: String.duplicate("5", 64),
      restart: "permanent",
      shutdown: "infinity",
      type: "supervisor"
    })

    exact_struct!(CompatibilityDiagnostic, %{
      schema_version: 1,
      code: :legacy_registry,
      severity: :warning,
      path: [path_segment],
      owner: owner,
      detail: %{source_lane: :legacy_plugin, legacy_index: 1}
    })

    exact_struct!(ValidationDiagnostic, %{
      schema_version: 1,
      code: :invalid_value,
      path: [path_segment],
      owner: owner,
      detail: %{reason: :unsupported}
    })
  end

  defp exact_struct!(module, attrs) do
    expected_keys = attrs |> Map.keys() |> Enum.sort()

    assert module.__struct__()
           |> Map.delete(:__struct__)
           |> Map.keys()
           |> Enum.sort() == expected_keys

    for key <- expected_keys do
      assert_raise ArgumentError, fn -> struct!(module, Map.delete(attrs, key)) end
    end

    assert struct!(module, attrs) == Map.put(attrs, :__struct__, module)
    struct!(module, attrs)
  end

  defp callback_rows do
    Map.new(
      [
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
      ],
      &{&1, []}
    )
  end
end
