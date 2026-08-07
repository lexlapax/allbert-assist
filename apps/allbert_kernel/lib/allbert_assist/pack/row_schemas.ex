defmodule AllbertAssist.Pack.RowSchemas do
  @moduledoc """
  Closed normalization boundary for Pack callback-row payloads.

  The JSON-compatible schema contract is the single field, type, ordering, and
  owner-reference inventory shared by adapters and canonical encoding. Input
  module strings are validated but never converted into atoms.
  """

  alias AllbertAssist.Pack.{Contribution, Descriptor, Owner, Row}

  defmodule Input do
    @moduledoc "Typed, untrusted input to the closed RowSchemas boundary."

    @enforce_keys [:payload, :source_authority]
    defstruct @enforce_keys

    @type t :: %__MODULE__{payload: map(), source_authority: map() | nil}
  end

  defmodule Normalized do
    @moduledoc false

    @enforce_keys [:schema, :payload, :source_authority, :validation_token]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            schema: atom(),
            payload: %{required(String.t()) => term()},
            source_authority: %{optional(String.t()) => term()} | nil,
            validation_token: term()
          }
  end

  @opaque normalized :: Normalized.t()

  field = fn name, type, nullable, list_semantics, owner_reference_source, values, min_items ->
    owner_reference =
      case owner_reference_source do
        "none" -> "none"
        "owner.application" -> "application_reference"
        _source -> "packaging_owner"
      end

    %{
      "name" => name,
      "type" => type,
      "required" => true,
      "nullable" => nullable,
      "list_semantics" => list_semantics,
      "owner_reference" => owner_reference,
      "owner_reference_source" =>
        if(owner_reference_source == "none", do: nil, else: owner_reference_source),
      "values" => values,
      "min_items" => min_items
    }
  end

  identity = fn namespace, payload_field ->
    %{"namespace" => namespace, "field" => payload_field}
  end

  numeric_order = %{
    "kind" => "numeric",
    "namespaces" => ["legacy_index", "registry_order"]
  }

  lexical_order = %{"kind" => "lexical", "namespaces" => ["lexical"]}
  no_order = %{"kind" => "none", "namespaces" => []}

  @schema_contract [
    %{
      "callback" => "apps",
      "payload_schema" => "app_descriptor_v1",
      "reserved_empty" => false,
      "identity" => identity.("app_id", "app_id"),
      "order" => numeric_order,
      "reference_digest_field" => "contract_sha256",
      "fields" => [
        field.("module", "module_string", false, "scalar", "none", [], nil),
        field.("app_id", "canonical_string", false, "scalar", "none", [], nil),
        field.("contract_sha256", "lowercase_sha256", false, "scalar", "none", [], nil)
      ]
    },
    %{
      "callback" => "actions",
      "payload_schema" => "action_ref_v1",
      "reserved_empty" => false,
      "identity" => identity.("action_name", "name"),
      "order" => numeric_order,
      "reference_digest_field" => "binding_sha256",
      "fields" => [
        field.("module", "module_string", false, "scalar", "none", [], nil),
        field.("name", "canonical_string", false, "scalar", "none", [], nil),
        field.("registry_order", "non_neg_integer", true, "scalar", "none", [], nil),
        field.("binding_sha256", "lowercase_sha256", false, "scalar", "none", [], nil)
      ]
    },
    %{
      "callback" => "settings_fragments",
      "payload_schema" => "settings_fragment_ref_v1",
      "reserved_empty" => false,
      "identity" => identity.("fragment_id", "fragment_id"),
      "order" => numeric_order,
      "reference_digest_field" => "projection_sha256",
      "fields" => [
        field.("fragment_id", "canonical_string", false, "scalar", "none", [], nil),
        field.(
          "owner_id",
          "canonical_string",
          false,
          "scalar",
          "owner.id",
          [],
          nil
        ),
        field.("schema_version", "positive_integer", false, "scalar", "none", [], nil),
        field.("projection_sha256", "lowercase_sha256", false, "scalar", "none", [], nil)
      ]
    },
    %{
      "callback" => "settings_migrations",
      "payload_schema" => "settings_migration_ref_v1",
      "reserved_empty" => true,
      "identity" => nil,
      "order" => no_order,
      "reference_digest_field" => nil,
      "fields" => []
    },
    %{
      "callback" => "channels",
      "payload_schema" => "channel_descriptor_v1",
      "reserved_empty" => false,
      "identity" => identity.("channel_id", "channel_id"),
      "order" => numeric_order,
      "reference_digest_field" => "projection_sha256",
      "fields" => [
        field.("channel_id", "canonical_string", false, "scalar", "none", [], nil),
        field.("module", "module_string", false, "scalar", "none", [], nil),
        field.("projection_sha256", "lowercase_sha256", false, "scalar", "none", [], nil)
      ]
    },
    %{
      "callback" => "surfaces",
      "payload_schema" => "surface_ref_v1",
      "reserved_empty" => false,
      "identity" => identity.("surface_id", "surface_id"),
      "order" => numeric_order,
      "reference_digest_field" => "projection_sha256",
      "fields" => [
        field.("surface_id", "canonical_string", false, "scalar", "none", [], nil),
        field.("module", "module_string", true, "scalar", "none", [], nil),
        field.("projection_sha256", "lowercase_sha256", false, "scalar", "none", [], nil)
      ]
    },
    %{
      "callback" => "skill_roots",
      "payload_schema" => "skill_root_v1",
      "reserved_empty" => false,
      "identity" => identity.("root_id", "root_id"),
      "order" => lexical_order,
      "reference_digest_field" => "projection_sha256",
      "fields" => [
        field.("root_id", "canonical_string", false, "scalar", "none", [], nil),
        field.("relative_path", "confined_relative_string", false, "scalar", "none", [], nil),
        field.("trust_policy", "canonical_string", false, "scalar", "none", [], nil),
        field.("projection_sha256", "lowercase_sha256", false, "scalar", "none", [], nil)
      ]
    },
    %{
      "callback" => "home_roots",
      "payload_schema" => "home_root_v1",
      "reserved_empty" => false,
      "identity" => identity.("root_id", "root_id"),
      "order" => lexical_order,
      "reference_digest_field" => "projection_sha256",
      "fields" => [
        field.("root_id", "canonical_string", false, "scalar", "none", [], nil),
        field.("relative_path", "confined_relative_string", false, "scalar", "none", [], nil),
        field.(
          "durability",
          "enum",
          false,
          "scalar",
          "none",
          ["durable", "regenerable", "ephemeral"],
          nil
        ),
        field.("backup", "enum", false, "scalar", "none", ["include", "exclude"], nil),
        field.("export", "enum", false, "scalar", "none", ["include", "exclude"], nil),
        field.(
          "rebuild",
          "enum",
          false,
          "scalar",
          "none",
          ["required", "optional", "none"],
          nil
        ),
        field.("projection_sha256", "lowercase_sha256", false, "scalar", "none", [], nil)
      ]
    },
    %{
      "callback" => "jobs",
      "payload_schema" => "job_ref_v1",
      "reserved_empty" => false,
      "identity" => identity.("job_id", "job_id"),
      "order" => numeric_order,
      "reference_digest_field" => "projection_sha256",
      "fields" => [
        field.("job_id", "canonical_string", false, "scalar", "none", [], nil),
        field.("module", "module_string", false, "scalar", "none", [], nil),
        field.("projection_sha256", "lowercase_sha256", false, "scalar", "none", [], nil)
      ]
    },
    %{
      "callback" => "stores",
      "payload_schema" => "store_ref_v1",
      "reserved_empty" => false,
      "identity" => identity.("store_id", "store_id"),
      "order" => numeric_order,
      "reference_digest_field" => "projection_sha256",
      "fields" => [
        field.("store_id", "canonical_string", false, "scalar", "none", [], nil),
        field.("module", "module_string", false, "scalar", "none", [], nil),
        field.("projection_sha256", "lowercase_sha256", false, "scalar", "none", [], nil)
      ]
    },
    %{
      "callback" => "prompt_rules",
      "payload_schema" => "prompt_rule_ref_v1",
      "reserved_empty" => false,
      "identity" => identity.("rule_id", "rule_id"),
      "order" => numeric_order,
      "reference_digest_field" => "projection_sha256",
      "fields" => [
        field.("rule_id", "canonical_string", false, "scalar", "none", [], nil),
        field.("module", "module_string", true, "scalar", "none", [], nil),
        field.("projection_sha256", "lowercase_sha256", false, "scalar", "none", [], nil)
      ]
    },
    %{
      "callback" => "intent_descriptors",
      "payload_schema" => "intent_descriptor_ref_v1",
      "reserved_empty" => false,
      "identity" => identity.("intent_id", "intent_id"),
      "order" => numeric_order,
      "reference_digest_field" => "projection_sha256",
      "fields" => [
        field.("intent_id", "canonical_string", false, "scalar", "none", [], nil),
        field.("module", "module_string", false, "scalar", "none", [], nil),
        field.("projection_sha256", "lowercase_sha256", false, "scalar", "none", [], nil)
      ]
    },
    %{
      "callback" => "cli_groups",
      "payload_schema" => "cli_group_ref_v1",
      "reserved_empty" => false,
      "identity" => identity.("group_id", "group_id"),
      "order" => numeric_order,
      "reference_digest_field" => "projection_sha256",
      "fields" => [
        field.("group_id", "canonical_string", false, "scalar", "none", [], nil),
        field.("command_path", "canonical_string", false, "ordered", "none", [], 1),
        field.("module", "module_string", false, "scalar", "none", [], nil),
        field.("projection_sha256", "lowercase_sha256", false, "scalar", "none", [], nil)
      ]
    },
    %{
      "callback" => "release_assets",
      "payload_schema" => "release_asset_v1",
      "reserved_empty" => false,
      "identity" => identity.("asset_id", "asset_id"),
      "order" => lexical_order,
      "reference_digest_field" => nil,
      "fields" => [
        field.("asset_id", "canonical_string", false, "scalar", "none", [], nil),
        field.("relative_path", "confined_relative_string", false, "scalar", "none", [], nil),
        field.("kind", "canonical_string", false, "scalar", "none", [], nil),
        field.(
          "component",
          "canonical_string",
          false,
          "scalar",
          "descriptor.provenance.component",
          [],
          nil
        ),
        field.("source_sha256", "lowercase_sha256", true, "scalar", "none", [], nil)
      ]
    },
    %{
      "callback" => "test_lanes",
      "payload_schema" => "test_lane_v1",
      "reserved_empty" => false,
      "identity" => identity.("owner_id", "owner_id"),
      "order" => lexical_order,
      "reference_digest_field" => "projection_sha256",
      "fields" => [
        field.(
          "owner_id",
          "canonical_string",
          false,
          "scalar",
          "owner.id",
          [],
          nil
        ),
        field.(
          "application",
          "canonical_string",
          false,
          "scalar",
          "owner.application",
          [],
          nil
        ),
        field.(
          "cwd",
          "confined_repository_relative_string",
          false,
          "scalar",
          "none",
          [],
          nil
        ),
        field.(
          "production_roots",
          "confined_repository_relative_string",
          false,
          "set",
          "none",
          [],
          0
        ),
        field.(
          "test_roots",
          "confined_repository_relative_string",
          false,
          "set",
          "none",
          [],
          0
        ),
        field.(
          "support_roots",
          "confined_repository_relative_string",
          false,
          "set",
          "none",
          [],
          0
        ),
        field.(
          "allowed_primary_lanes",
          "canonical_string",
          false,
          "set",
          "none",
          [],
          0
        ),
        field.("aggregate_policy", "canonical_string", false, "scalar", "none", [], nil),
        field.(
          "target_resolver_module",
          "module_string",
          false,
          "scalar",
          "none",
          [],
          nil
        ),
        field.(
          "target_resolver_function",
          "canonical_string",
          false,
          "scalar",
          "none",
          [],
          nil
        ),
        field.(
          "historical_metrics_aliases",
          "canonical_string",
          false,
          "set",
          "none",
          [],
          0
        ),
        field.("projection_sha256", "lowercase_sha256", false, "scalar", "none", [], nil)
      ]
    }
  ]

  authority_field = fn name, type, nullable, list_semantics, values, min_items ->
    %{
      "name" => name,
      "type" => type,
      "required" => true,
      "nullable" => nullable,
      "list_semantics" => list_semantics,
      "values" => values,
      "min_items" => min_items,
      "owner_reference" => "none",
      "owner_reference_source" => nil
    }
  end

  exact_object = fn fields, definitions ->
    %{
      "kind" => "exact_object",
      "nullable" => false,
      "fields" => fields,
      "definitions" => definitions
    }
  end

  no_authority = %{"kind" => "none", "nullable" => true, "fields" => [], "definitions" => %{}}
  empty_authority = exact_object.([], %{})

  capability_fields = [
    authority_field.("app_id", "canonical_string", true, "scalar", [], nil),
    authority_field.("confirmation", "canonical_string", true, "scalar", [], nil),
    authority_field.("execution_mode", "canonical_string", false, "scalar", [], nil),
    authority_field.("exposure", "canonical_string", false, "scalar", [], nil),
    authority_field.("notes", "string", true, "scalar", [], nil),
    authority_field.("permission", "canonical_string", false, "scalar", [], nil),
    authority_field.("plugin_id", "canonical_string", true, "scalar", [], nil),
    authority_field.("resumable?", "boolean", false, "scalar", [], nil),
    authority_field.("retry_safety", "canonical_string", false, "scalar", [], nil),
    authority_field.("skill_backed?", "boolean", false, "scalar", [], nil)
  ]

  intent_capability_fields = [
    authority_field.("name", "canonical_string", false, "scalar", [], nil),
    authority_field.("module", "module_string", true, "scalar", [], nil),
    authority_field.("registered?", "boolean", false, "scalar", [], nil),
    authority_field.("permission", "canonical_string", false, "scalar", [], nil),
    authority_field.("exposure", "canonical_string", false, "scalar", [], nil),
    authority_field.("execution_mode", "canonical_string", false, "scalar", [], nil),
    authority_field.("skill_backed?", "boolean", false, "scalar", [], nil),
    authority_field.("confirmation", "canonical_string", true, "scalar", [], nil),
    authority_field.("resumable?", "boolean", false, "scalar", [], nil),
    authority_field.("retry_safety", "canonical_string", true, "scalar", [], nil),
    authority_field.("app_id", "canonical_string", true, "scalar", [], nil),
    authority_field.("plugin_id", "canonical_string", true, "scalar", [], nil)
  ]

  app_definitions = %{
    "app_signals_v1" => %{
      "kind" => "exact_object",
      "fields" => [
        authority_field.("emits", "canonical_string", false, "ordered", [], 0),
        authority_field.("subscribes", "canonical_string", false, "ordered", [], 0)
      ]
    },
    "memory_namespace_v1" => %{
      "kind" => "exact_object",
      "fields" => [
        authority_field.("app_id", "canonical_string", false, "scalar", [], nil),
        authority_field.("namespace", "canonical_string", false, "scalar", [], nil),
        authority_field.("writable", "boolean", false, "scalar", [], nil),
        authority_field.("description", "string", true, "scalar", [], nil)
      ]
    },
    "surface_ref_authority_v1" => %{
      "kind" => "exact_object",
      "fields" => [
        authority_field.("surface_id", "canonical_string", false, "scalar", [], nil),
        authority_field.("projection_sha256", "lowercase_sha256", false, "scalar", [], nil)
      ]
    },
    "surface_catalog_entry_v1" => %{
      "kind" => "exact_object",
      "fields" => [
        authority_field.("component", "canonical_string", false, "scalar", [], nil),
        authority_field.("allowed_props", "canonical_string", false, "ordered", [], 0),
        authority_field.("allowed_bindings", "canonical_string", false, "ordered", [], 0)
      ]
    },
    "app_action_ref_v1" => %{
      "kind" => "exact_object",
      "fields" => [
        authority_field.("module", "module_string", false, "scalar", [], nil),
        authority_field.("name", "canonical_string", false, "scalar", [], nil),
        authority_field.("binding_sha256", "lowercase_sha256", false, "scalar", [], nil)
      ]
    },
    "skill_root_ref_authority_v1" => %{
      "kind" => "exact_object",
      "fields" => [
        authority_field.("owner_id", "canonical_string", false, "scalar", [], nil)
        |> Map.merge(%{
          "owner_reference" => "packaging_owner",
          "owner_reference_source" => "owner.id"
        }),
        authority_field.("root_id", "canonical_string", false, "scalar", [], nil),
        authority_field.("projection_sha256", "lowercase_sha256", false, "scalar", [], nil)
      ]
    },
    "settings_fragment_ref_authority_v1" => %{
      "kind" => "exact_object",
      "fields" => [
        authority_field.("fragment_id", "canonical_string", false, "scalar", [], nil),
        authority_field.("projection_sha256", "lowercase_sha256", false, "scalar", [], nil)
      ]
    },
    "intent_ref_authority_v1" => %{
      "kind" => "exact_object",
      "fields" => [
        authority_field.("intent_id", "canonical_string", false, "scalar", [], nil),
        authority_field.("projection_sha256", "lowercase_sha256", false, "scalar", [], nil)
      ]
    }
  }

  channel_definitions = %{
    "session_strategy_v1" => %{
      "kind" => "exact_object",
      "fields" => [
        authority_field.("strategy", "canonical_string", false, "scalar", [], nil),
        authority_field.("options", "session_option_v1", false, "ordered", [], 0)
      ]
    },
    "session_option_v1" => %{
      "kind" => "exact_object",
      "fields" => [
        authority_field.("key", "canonical_string", false, "scalar", [], nil),
        authority_field.("value", "closed_safe_term_v1", false, "scalar", [], nil)
      ]
    },
    "descriptor_child_spec_v1" => %{
      "kind" => "exact_object",
      "fields" => [
        authority_field.("kind", "enum", false, "scalar", ["module_options"], nil),
        authority_field.("module", "module_string", false, "scalar", [], nil),
        authority_field.("options", "closed_safe_term_v1", false, "ordered", [], 0)
      ]
    }
  }

  surface_binding_fields = [
    authority_field.("action_name", "canonical_string", false, "scalar", [], nil),
    authority_field.("action_module", "module_string", true, "scalar", [], nil),
    authority_field.("permission", "canonical_string", true, "scalar", [], nil),
    authority_field.("app_id", "canonical_string", true, "scalar", [], nil),
    authority_field.("plugin_id", "canonical_string", true, "scalar", [], nil),
    authority_field.("confirmation_required?", "boolean", true, "scalar", [], nil)
  ]

  surface_definitions = %{
    "surface_binding_v1" => %{
      "kind" => "exact_object",
      "fields" => surface_binding_fields
    },
    "surface_node_v1" => %{
      "kind" => "exact_object",
      "fields" => [
        authority_field.("id", "canonical_string", false, "scalar", [], nil),
        authority_field.("component", "canonical_string", false, "scalar", [], nil),
        authority_field.("props", "safe_surface_map_v1", false, "scalar", [], nil),
        authority_field.("bindings", "surface_binding_v1", false, "ordered", [], 0),
        authority_field.("children", "surface_node_v1", false, "ordered", [], 0)
      ]
    }
  }

  source_authorities = %{
    "app_descriptor_v1" =>
      exact_object.(
        [
          authority_field.("app_id", "canonical_string", false, "scalar", [], nil),
          authority_field.("module", "module_string", false, "scalar", [], nil),
          authority_field.("display_name", "canonical_string", false, "scalar", [], nil),
          authority_field.("version", "canonical_string", false, "scalar", [], nil),
          authority_field.("actions", "app_action_ref_v1", false, "ordered", [], 0),
          authority_field.("agents", "module_string", false, "ordered", [], 0),
          authority_field.("signals", "app_signals_v1", false, "scalar", [], nil),
          authority_field.("memory_namespace", "memory_namespace_v1", true, "scalar", [], nil),
          authority_field.("surface_provider", "module_string", true, "scalar", [], nil),
          authority_field.("surface_refs", "surface_ref_authority_v1", false, "ordered", [], 0),
          authority_field.(
            "surface_catalog",
            "surface_catalog_entry_v1",
            false,
            "ordered",
            [],
            0
          ),
          authority_field.(
            "skill_root_refs",
            "skill_root_ref_authority_v1",
            false,
            "ordered",
            [],
            0
          ),
          authority_field.(
            "settings_fragment_refs",
            "settings_fragment_ref_authority_v1",
            false,
            "ordered",
            [],
            0
          ),
          authority_field.(
            "intent_descriptor_refs",
            "intent_ref_authority_v1",
            false,
            "ordered",
            [],
            0
          ),
          authority_field.("child_id", "canonical_child_id", true, "scalar", [], nil),
          authority_field.("metadata", "closed_safe_term_v1", false, "scalar", [], nil)
        ],
        app_definitions
      ),
    "action_ref_v1" =>
      exact_object.(
        [
          authority_field.("kind", "enum", false, "scalar", ["action"], nil),
          authority_field.("module", "module_string", false, "scalar", [], nil),
          authority_field.("name", "canonical_string", false, "scalar", [], nil),
          authority_field.(
            "normalized_capability",
            "normalized_capability_v1",
            false,
            "scalar",
            [],
            nil
          ),
          authority_field.("input_schema_sha256", "lowercase_sha256", false, "scalar", [], nil),
          authority_field.("output_schema_sha256", "lowercase_sha256", false, "scalar", [], nil)
        ],
        %{
          "normalized_capability_v1" => %{
            "kind" => "exact_object",
            "fields" => capability_fields
          }
        }
      ),
    "settings_fragment_ref_v1" =>
      exact_object.(
        [
          authority_field.("fragment_id", "canonical_string", false, "scalar", [], nil),
          authority_field.("legacy_owner_id", "canonical_string", false, "scalar", [], nil),
          authority_field.("source", "enum", false, "scalar", ["core", "app", "plugin"], nil),
          authority_field.("group", "canonical_string", true, "scalar", [], nil),
          authority_field.("schema_version", "positive_integer", false, "scalar", [], nil),
          authority_field.("schema", "settings_schema_map_v1", false, "scalar", [], nil),
          authority_field.("defaults", "safe_setting_value_v1", false, "scalar", [], nil),
          authority_field.("safe_write_keys", "canonical_string", false, "ordered", [], 0),
          authority_field.("metadata", "closed_safe_term_v1", false, "scalar", [], nil)
        ],
        %{
          "settings_schema_map_v1" => %{
            "kind" => "variable_map",
            "key_type" => "canonical_string",
            "value_type" => "settings_schema_entry_v1"
          },
          "settings_schema_entry_v1" => %{
            "kind" => "settings_schema_entry",
            "required_fields" => ["type", "default", "writable?", "sensitive?"],
            "optional_fields" => [
              "allowed_values",
              "min",
              "max",
              "deprecated?",
              "deprecation_reason",
              "surface"
            ]
          }
        }
      ),
    "channel_descriptor_v1" =>
      exact_object.(
        [
          authority_field.("plugin_id", "canonical_string", false, "scalar", [], nil)
          |> Map.merge(%{
            "owner_reference" => "packaging_owner",
            "owner_reference_source" => "owner.id"
          }),
          authority_field.("channel_id", "canonical_string", false, "scalar", [], nil),
          authority_field.("adapter", "module_string", false, "scalar", [], nil),
          authority_field.("provider", "canonical_string", false, "scalar", [], nil),
          authority_field.(
            "source",
            "enum",
            false,
            "scalar",
            ["shipped", "project", "home"],
            nil
          ),
          authority_field.(
            "status",
            "enum",
            false,
            "scalar",
            ["enabled", "disabled", "invalid", "rejected"],
            nil
          ),
          authority_field.("settings_prefix", "canonical_string", false, "scalar", [], nil),
          authority_field.("identity_map_key", "canonical_string", false, "scalar", [], nil),
          authority_field.(
            "primitives",
            "enum",
            false,
            "ordered",
            ["button", "typed_command", "link", "list"],
            0
          ),
          authority_field.(
            "threading",
            "enum",
            false,
            "scalar",
            ["native_threads", "reply_chain", "flat", "rich"],
            nil
          ),
          authority_field.("streaming", "canonical_string", false, "scalar", [], nil),
          authority_field.("session_strategy", "session_strategy_v1", false, "scalar", [], nil),
          authority_field.(
            "trust_class",
            "enum",
            false,
            "scalar",
            ["e2ee_origin", "server_readable", "local"],
            nil
          ),
          authority_field.("secret_refs", "canonical_string", false, "ordered", [], 0),
          authority_field.("summary_fields", "canonical_string", false, "ordered", [], 0),
          authority_field.("can_create_thread", "boolean", true, "scalar", [], nil),
          authority_field.(
            "reply_key_type",
            "enum",
            true,
            "scalar",
            ["opaque_id", "timestamp"],
            nil
          ),
          authority_field.("quote_ttl_ms", "non_neg_integer", true, "scalar", [], nil),
          authority_field.("status_update_mode", "canonical_string", true, "scalar", [], nil),
          authority_field.("child_spec", "descriptor_child_spec_v1", false, "scalar", [], nil)
        ],
        channel_definitions
      ),
    "surface_ref_v1" =>
      exact_object.(
        [
          authority_field.("id", "canonical_string", false, "scalar", [], nil),
          authority_field.("app_id", "canonical_string", false, "scalar", [], nil),
          authority_field.("label", "string", false, "scalar", [], nil),
          authority_field.("path", "string", false, "scalar", [], nil),
          authority_field.("kind", "canonical_string", false, "scalar", [], nil),
          authority_field.("zone", "canonical_string", true, "scalar", [], nil),
          authority_field.("status", "canonical_string", false, "scalar", [], nil),
          authority_field.("nodes", "surface_node_v1", false, "ordered", [], 0),
          authority_field.("fallback_text", "string", true, "scalar", [], nil),
          authority_field.("metadata", "safe_surface_map_v1", false, "scalar", [], nil)
        ],
        surface_definitions
      ),
    "intent_descriptor_ref_v1" =>
      exact_object.(
        [
          authority_field.("intent_id", "canonical_string", false, "scalar", [], nil),
          authority_field.("app_id", "canonical_string", false, "scalar", [], nil),
          authority_field.("action_name", "canonical_string", false, "scalar", [], nil),
          authority_field.("label", "string", false, "scalar", [], nil),
          authority_field.("source", "canonical_string", true, "scalar", [], nil),
          authority_field.("source_module", "module_string", true, "scalar", [], nil),
          authority_field.("destination", "string", true, "scalar", [], nil),
          authority_field.("selection_policy", "canonical_string", false, "scalar", [], nil),
          authority_field.("examples", "string", false, "ordered", [], 0),
          authority_field.("synonyms", "string", false, "ordered", [], 0),
          authority_field.("required_slots", "canonical_string", false, "ordered", [], 0),
          authority_field.("optional_slots", "canonical_string", false, "ordered", [], 0),
          authority_field.("slot_extractors", "slot_extractor_map_v1", false, "scalar", [], nil),
          authority_field.("vocabulary", "intent_vocabulary_v1", false, "scalar", [], nil),
          authority_field.("handoff_required", "boolean", false, "scalar", [], nil),
          authority_field.("routable_by_default", "boolean", false, "scalar", [], nil),
          authority_field.("capability", "normalized_capability_v1", false, "scalar", [], nil)
        ],
        %{
          "slot_extractor_map_v1" => %{
            "kind" => "variable_map",
            "key_type" => "canonical_string",
            "value_type" => "intent_slot_extractor_v1"
          },
          "intent_slot_extractor_v1" => %{
            "kind" => "enum",
            "values" => [
              "ticker_symbol",
              "title_phrase",
              "body_phrase",
              "memory_phrase",
              "note_path_phrase",
              "email_address",
              "message_body_phrase",
              "channel_name_phrase",
              "channel_target_phrase",
              "calendar_title_phrase",
              "calendar_start_phrase",
              "url_phrase"
            ]
          },
          "intent_vocabulary_v1" => %{
            "kind" => "exact_object",
            "fields" => [
              authority_field.("phrases", "string", false, "ordered", [], 0),
              authority_field.("negative_phrases", "string", false, "ordered", [], 0),
              authority_field.("selection_phrases", "string", false, "ordered", [], 0),
              authority_field.(
                "selection_negative_phrases",
                "string",
                false,
                "ordered",
                [],
                0
              ),
              authority_field.("clarification_phrases", "string", false, "ordered", [], 0),
              authority_field.("allow_single_token_match", "boolean", false, "scalar", [], nil),
              authority_field.(
                "allow_required_slot_selection",
                "boolean",
                false,
                "scalar",
                [],
                nil
              )
            ]
          },
          "normalized_capability_v1" => %{
            "kind" => "exact_object",
            "fields" => intent_capability_fields
          }
        }
      ),
    "skill_root_v1" => empty_authority,
    "home_root_v1" => empty_authority,
    "job_ref_v1" => empty_authority,
    "store_ref_v1" => empty_authority,
    "prompt_rule_ref_v1" => empty_authority,
    "cli_group_ref_v1" => empty_authority,
    "test_lane_v1" => empty_authority,
    "release_asset_v1" => no_authority,
    "settings_migration_ref_v1" => no_authority
  }

  base_schema_contract = @schema_contract

  @schema_contract Enum.map(base_schema_contract, fn entry ->
                     Map.put(
                       entry,
                       "source_authority",
                       Map.fetch!(source_authorities, entry["payload_schema"])
                     )
                   end)

  @contract_atom_names @schema_contract
                       |> Enum.flat_map(fn entry ->
                         identity_names =
                           case entry["identity"] do
                             nil -> []
                             identity -> [identity["namespace"]]
                           end

                         [entry["callback"], entry["payload_schema"]] ++
                           identity_names ++ entry["order"]["namespaces"]
                       end)
                       |> Enum.uniq()

  @contract_atoms Map.new(@contract_atom_names, &{&1, String.to_atom(&1)})
  @callback_atoms Enum.map(@schema_contract, &Map.fetch!(@contract_atoms, &1["callback"]))
  @schema_atoms Map.new(@schema_contract, fn entry ->
                  name = entry["payload_schema"]
                  {name, Map.fetch!(@contract_atoms, name)}
                end)

  @sha256 ~r/\A[0-9a-f]{64}\z/
  @module_string ~r/\A[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z/
  @alias_owner "<ALIAS_OWNER>"
  @validation_token {__MODULE__, :normalized_v1}

  @doc "Returns the inert, JSON-compatible schema inventory in callback order."
  def schema_contract, do: @schema_contract

  @doc "Returns callback names in their frozen canonical order."
  @spec callback_order() :: nonempty_list(atom())
  def callback_order, do: @callback_atoms

  @doc "Returns the sole payload schema assigned to a callback."
  @spec payload_schema_for!(atom()) :: atom()
  def payload_schema_for!(callback) when is_atom(callback) do
    callback_name = Atom.to_string(callback)

    case Enum.find(@schema_contract, &(&1["callback"] == callback_name)) do
      nil ->
        raise ArgumentError, "unsupported Pack callback: #{inspect(callback)}"

      contract ->
        Map.fetch!(@schema_atoms, contract["payload_schema"])
    end
  end

  def payload_schema_for!(callback) do
    raise ArgumentError, "unsupported Pack callback: #{inspect(callback)}"
  end

  @doc "Validates and normalizes one payload without creating atoms from input."
  @spec normalize!(atom(), Input.t()) :: normalized()
  def normalize!(schema, %Input{} = input) when is_atom(schema) do
    {contract, normalized_payload, normalized_authority} = normalize_input!(schema, input)

    verify_reference_digest!(
      schema,
      normalized_payload,
      normalized_authority,
      contract["reference_digest_field"]
    )

    %Normalized{
      schema: schema,
      payload: normalized_payload,
      source_authority: normalized_authority,
      validation_token: @validation_token
    }
  end

  def normalize!(schema, _input) do
    if is_atom(schema) do
      raise ArgumentError, "RowSchemas.normalize!/2 requires a RowSchemas.Input"
    else
      raise ArgumentError, "unsupported Pack row payload schema: #{inspect(schema)}"
    end
  end

  @doc "Computes the schema-owned reference digest without trusting its stored value."
  @spec reference_digest_for!(atom(), Input.t()) :: String.t() | nil
  def reference_digest_for!(schema, %Input{} = input) when is_atom(schema) do
    {contract, normalized_payload, normalized_authority} = normalize_input!(schema, input)

    case contract["reference_digest_field"] do
      nil ->
        nil

      digest_field ->
        reference_digest(
          schema,
          Map.delete(normalized_payload, digest_field),
          normalized_authority
        )
    end
  end

  def reference_digest_for!(schema, _input) do
    if is_atom(schema) do
      raise ArgumentError, "RowSchemas.reference_digest_for!/2 requires a RowSchemas.Input"
    else
      raise ArgumentError, "unsupported Pack row payload schema: #{inspect(schema)}"
    end
  end

  @doc "Returns canonical JSON authority only for a successfully normalized payload."
  @spec canonical_projection(normalized()) :: map()
  def canonical_projection(%Normalized{
        schema: schema,
        payload: payload,
        source_authority: _source_authority,
        validation_token: @validation_token
      })
      when is_atom(schema) and is_map(payload),
      do: payload

  def canonical_projection(_value) do
    raise ArgumentError, "expected a value returned by RowSchemas.normalize!/2"
  end

  @doc "Returns normalized source authority only for a successfully normalized payload."
  @spec source_authority_projection(normalized()) :: map() | nil
  def source_authority_projection(%Normalized{
        schema: schema,
        payload: payload,
        source_authority: source_authority,
        validation_token: @validation_token
      })
      when is_atom(schema) and is_map(payload) and
             (is_map(source_authority) or is_nil(source_authority)),
      do: source_authority

  def source_authority_projection(_value) do
    raise ArgumentError, "expected a value returned by RowSchemas.normalize!/2"
  end

  @doc "Builds the owner-neutral authority projection for one validated callback Row."
  @spec alias_authority_projection!(Row.t(), Contribution.t()) :: map()
  def alias_authority_projection!(
        %Row{} = row,
        %Contribution{schema_version: 1, owner: %Owner{}} = contribution
      ) do
    contract = validate_row_envelope!(row, contribution)

    normalized =
      row.payload_schema
      |> normalize!(%Input{payload: row.payload, source_authority: row.source_authority})

    payload = canonical_projection(normalized)
    source_authority = source_authority_projection(normalized)

    validate_identity!(row, contract, payload)
    validate_order!(row, contract)
    validate_m0_digest!(row.m0_payload_sha256)

    neutral_payload = owner_neutral_authority(contract, payload, contribution)

    neutral_source_authority =
      owner_neutral_source_authority(contract, source_authority, contribution)

    authority =
      neutral_payload
      |> recompute_reference_digest(
        row.payload_schema,
        neutral_source_authority,
        contract["reference_digest_field"]
      )

    %{
      "kind" => Atom.to_string(row.kind),
      "identity" => owner_neutral_identity(row, contract),
      "order_value" => owner_neutral_order_value(row, contract),
      "payload_schema" => Atom.to_string(row.payload_schema),
      "authority" => authority
    }
  end

  def alias_authority_projection!(_row, _contribution) do
    raise ArgumentError, "alias authority requires a Pack.Row and Pack.Contribution"
  end

  defp contract_for_schema!(schema) do
    schema_name = Atom.to_string(schema)

    case Enum.find(@schema_contract, &(&1["payload_schema"] == schema_name)) do
      nil -> raise ArgumentError, "unsupported Pack row payload schema: #{inspect(schema)}"
      contract -> contract
    end
  end

  defp contract_for_callback!(callback) do
    callback_name = Atom.to_string(callback)

    case Enum.find(@schema_contract, &(&1["callback"] == callback_name)) do
      nil -> raise ArgumentError, "unsupported Pack callback: #{inspect(callback)}"
      contract -> contract
    end
  end

  defp normalize_input!(schema, %Input{payload: raw_payload, source_authority: authority}) do
    contract = contract_for_schema!(schema)

    if contract["reserved_empty"] do
      raise ArgumentError, "Pack row payload schema #{schema} is reserved empty"
    end

    fields = contract["fields"]
    payload = normalize_keys!(raw_payload, Enum.map(fields, & &1["name"]))

    normalized_payload =
      Map.new(fields, fn field ->
        name = field["name"]
        {name, normalize_field!(field, Map.fetch!(payload, name))}
      end)

    normalized_authority = normalize_source_authority!(contract["source_authority"], authority)
    {contract, normalized_payload, normalized_authority}
  end

  defp normalize_source_authority!(%{"kind" => "none"}, nil), do: nil

  defp normalize_source_authority!(%{"kind" => "none"}, _authority) do
    raise ArgumentError, "this Pack row schema requires nil source authority"
  end

  defp normalize_source_authority!(%{"kind" => "exact_object"} = spec, authority)
       when is_map(authority) do
    normalize_authority_object!(authority, spec["fields"], spec["definitions"] || %{})
  end

  defp normalize_source_authority!(%{"kind" => "exact_object"}, _authority) do
    raise ArgumentError, "this Pack row schema requires exact object source authority"
  end

  defp normalize_authority_object!(value, fields, definitions) when is_map(value) do
    payload = normalize_keys!(value, Enum.map(fields, & &1["name"]))

    Map.new(fields, fn field ->
      name = field["name"]
      field = Map.put(field, "definitions", definitions)
      {name, normalize_field!(field, Map.fetch!(payload, name))}
    end)
  end

  defp normalize_keys!(raw_payload, allowed_fields) when is_map(raw_payload) do
    normalized =
      Enum.reduce(raw_payload, %{}, fn {key, value}, acc ->
        field = field_name!(key)

        if Map.has_key?(acc, field) do
          raise ArgumentError, "duplicate Pack row payload field: #{inspect(field)}"
        end

        Map.put(acc, field, value)
      end)

    fields = Map.keys(normalized)
    missing = allowed_fields -- fields
    extra = fields -- allowed_fields

    cond do
      missing != [] ->
        raise ArgumentError,
              "missing Pack row payload fields: #{inspect(Enum.sort(missing))}"

      extra != [] ->
        raise ArgumentError,
              "unknown Pack row payload fields: #{inspect(Enum.sort(extra))}"

      true ->
        normalized
    end
  end

  defp normalize_keys!(_raw_payload, _allowed_fields) do
    raise ArgumentError, "Pack row payload must be a map"
  end

  defp field_name!(field) when is_atom(field), do: Atom.to_string(field)
  defp field_name!(field) when is_binary(field), do: field

  defp field_name!(_field) do
    raise ArgumentError, "Pack row payload keys must be atoms or strings"
  end

  defp normalize_field!(%{"nullable" => true}, nil), do: nil

  defp normalize_field!(%{"list_semantics" => "scalar"} = field, value) do
    normalize_scalar!(field, value)
  end

  defp normalize_field!(%{"list_semantics" => semantics} = field, value)
       when semantics in ["ordered", "set"] and is_list(value) do
    min_items = field["min_items"] || 0

    if length(value) < min_items do
      raise ArgumentError,
            "Pack row payload field #{inspect(field["name"])} requires at least #{min_items} items"
    end

    normalized = Enum.map(value, &normalize_scalar!(field, &1))

    case semantics do
      "ordered" -> normalized
      "set" -> normalized |> Enum.uniq() |> Enum.sort()
    end
  end

  defp normalize_field!(field, _value) do
    raise ArgumentError,
          "invalid type for Pack row payload field #{inspect(field["name"])}: expected #{field["list_semantics"]} value"
  end

  defp normalize_scalar!(%{"type" => "module_string"} = field, value),
    do: module_string!(value, field["name"])

  defp normalize_scalar!(%{"type" => "canonical_string"} = field, value),
    do: canonical_string!(value, field["name"])

  defp normalize_scalar!(%{"type" => "lowercase_sha256"} = field, value),
    do: sha256!(value, field["name"])

  defp normalize_scalar!(%{"type" => "string"} = field, value),
    do: string!(value, field["name"])

  defp normalize_scalar!(%{"type" => "boolean"}, value) when is_boolean(value), do: value

  defp normalize_scalar!(%{"type" => "non_neg_integer"}, value)
       when is_integer(value) and value >= 0,
       do: value

  defp normalize_scalar!(%{"type" => "positive_integer"}, value)
       when is_integer(value) and value > 0,
       do: value

  defp normalize_scalar!(%{"type" => "enum"} = field, value) do
    normalized = canonical_string!(value, field["name"])

    if normalized in field["values"] do
      normalized
    else
      raise ArgumentError,
            "invalid Pack row payload field #{inspect(field["name"])}: expected one of #{inspect(field["values"])}"
    end
  end

  defp normalize_scalar!(%{"type" => type} = field, value)
       when type in ["confined_relative_string", "confined_repository_relative_string"],
       do: confined_path!(value, field["name"])

  defp normalize_scalar!(%{"type" => "canonical_child_id"} = field, value),
    do: canonical_child_id!(value, field["name"])

  defp normalize_scalar!(%{"type" => "closed_safe_term_v1"}, value),
    do: normalize_safe_term!(value, true)

  defp normalize_scalar!(%{"type" => "safe_setting_value_v1"}, value),
    do: normalize_safe_term!(value, false)

  defp normalize_scalar!(%{"type" => "safe_surface_map_v1"} = field, value) do
    normalized = normalize_safe_term!(value, true)

    if is_map(normalized) and safe_surface_data?(normalized) do
      normalized
    else
      raise ArgumentError,
            "invalid surface-safe map for Pack row authority field #{inspect(field["name"])}"
    end
  end

  defp normalize_scalar!(%{"definitions" => definitions, "type" => type} = field, value)
       when is_map(definitions) do
    case Map.fetch(definitions, type) do
      {:ok, definition} ->
        normalize_authority_definition!(definition, value, definitions, field)

      :error ->
        raise ArgumentError,
              "invalid type for Pack row payload field #{inspect(field["name"])}: expected #{type}"
    end
  end

  defp normalize_scalar!(field, _value) do
    raise ArgumentError,
          "invalid type for Pack row payload field #{inspect(field["name"])}: expected #{field["type"]}"
  end

  defp normalize_authority_definition!(
         %{"kind" => "exact_object", "fields" => fields},
         value,
         definitions,
         _field
       )
       when is_map(value),
       do: normalize_authority_object!(value, fields, definitions)

  defp normalize_authority_definition!(
         %{"kind" => "variable_map", "value_type" => value_type} = definition,
         value,
         definitions,
         field
       )
       when is_map(value) do
    normalized = normalize_variable_map!(value, value_type, definitions, field["name"])
    min_size = definition["min_size"] || 0

    if map_size(normalized) >= min_size do
      normalized
    else
      raise ArgumentError,
            "Pack row authority field #{inspect(field["name"])} requires at least #{min_size} entries"
    end
  end

  defp normalize_authority_definition!(
         %{"kind" => "enum", "values" => values},
         value,
         _definitions,
         field
       ) do
    normalized = canonical_string!(value, field["name"])

    if normalized in values do
      normalized
    else
      raise ArgumentError,
            "invalid Pack row authority field #{inspect(field["name"])} enum value"
    end
  end

  defp normalize_authority_definition!(
         %{"kind" => "settings_schema_entry"} = definition,
         value,
         _definitions,
         field
       )
       when is_map(value),
       do: normalize_settings_schema_entry!(value, definition, field["name"])

  defp normalize_authority_definition!(_definition, _value, _definitions, field) do
    raise ArgumentError,
          "invalid authority value for Pack row field #{inspect(field["name"])}"
  end

  defp normalize_variable_map!(value, value_type, definitions, field_name) do
    Enum.reduce(value, %{}, fn {raw_key, nested}, normalized ->
      key = raw_key |> field_name!() |> canonical_string!(field_name)

      if Map.has_key?(normalized, key) do
        raise ArgumentError, "duplicate normalized authority map key: #{inspect(key)}"
      end

      nested_field = %{
        "name" => key,
        "type" => value_type,
        "nullable" => false,
        "list_semantics" => "scalar",
        "values" => [],
        "min_items" => nil,
        "definitions" => definitions
      }

      Map.put(normalized, key, normalize_field!(nested_field, nested))
    end)
  end

  defp normalize_settings_schema_entry!(value, definition, field_name) do
    normalized_keys = normalize_open_keys!(value)
    required = definition["required_fields"]
    optional = definition["optional_fields"]
    keys = Map.keys(normalized_keys)
    missing = required -- keys
    extra = keys -- (required ++ optional)

    cond do
      missing != [] ->
        raise ArgumentError,
              "missing settings schema entry fields: #{inspect(Enum.sort(missing))}"

      extra != [] ->
        raise ArgumentError, "unknown settings schema entry fields: #{inspect(Enum.sort(extra))}"

      true ->
        Map.new(normalized_keys, fn {key, nested} ->
          {key, normalize_settings_schema_entry_field!(key, nested, field_name)}
        end)
    end
  end

  defp normalize_settings_schema_entry_field!("type", value, field),
    do: canonical_string!(value, field)

  defp normalize_settings_schema_entry_field!("default", value, _field),
    do: normalize_safe_term!(value, false)

  defp normalize_settings_schema_entry_field!(key, value, _field)
       when key in ["writable?", "sensitive?", "deprecated?"] and is_boolean(value),
       do: value

  defp normalize_settings_schema_entry_field!("allowed_values", value, field)
       when is_list(value),
       do: Enum.map(value, &normalize_safe_scalar!(&1, field))

  defp normalize_settings_schema_entry_field!(key, value, _field)
       when key in ["min", "max"] and (is_integer(value) or is_float(value)),
       do: finite_number!(value)

  defp normalize_settings_schema_entry_field!("deprecation_reason", nil, _field), do: nil

  defp normalize_settings_schema_entry_field!("deprecation_reason", value, field),
    do: string!(value, field)

  defp normalize_settings_schema_entry_field!("surface", value, _field),
    do: normalize_safe_term!(value, true)

  defp normalize_settings_schema_entry_field!(key, _value, _field) do
    raise ArgumentError, "invalid settings schema entry field #{inspect(key)}"
  end

  defp normalize_open_keys!(value) do
    Enum.reduce(value, %{}, fn {raw_key, nested}, normalized ->
      key = field_name!(raw_key)

      if Map.has_key?(normalized, key) do
        raise ArgumentError, "duplicate normalized authority map key: #{inspect(key)}"
      end

      Map.put(normalized, key, nested)
    end)
  end

  defp normalize_safe_scalar!(value, _field)
       when is_nil(value) or is_boolean(value) or is_integer(value),
       do: value

  defp normalize_safe_scalar!(value, _field) when is_float(value), do: finite_number!(value)
  defp normalize_safe_scalar!(value, field) when is_binary(value), do: string!(value, field)

  defp normalize_safe_scalar!(_value, field) do
    raise ArgumentError, "invalid safe scalar in settings schema field #{inspect(field)}"
  end

  defp normalize_safe_term!(value, _allow_atoms)
       when is_nil(value) or is_boolean(value) or is_integer(value),
       do: value

  defp normalize_safe_term!(value, _allow_atoms) when is_float(value),
    do: finite_number!(value)

  defp normalize_safe_term!(value, _allow_atoms) when is_binary(value) do
    normalized = string!(value, "safe_term")

    if raw_filesystem_root?(normalized) do
      raise ArgumentError, "absolute filesystem strings require a symbolic root projection"
    end

    normalized
  end

  defp normalize_safe_term!(value, true)
       when is_atom(value) and value not in [nil, true, false] do
    inspected = inspect(value)

    if Regex.match?(@module_string, inspected) do
      inspected
    else
      canonical_string!(value, "safe_term")
    end
  end

  defp normalize_safe_term!(value, allow_atoms) when is_list(value),
    do: Enum.map(value, &normalize_safe_term!(&1, allow_atoms))

  defp normalize_safe_term!(%{__struct__: _module}, _allow_atoms) do
    raise ArgumentError, "structs are not permitted in Pack row safe authority"
  end

  defp normalize_safe_term!(value, allow_atoms) when is_map(value) do
    value
    |> normalize_open_keys!()
    |> Map.new(fn {key, nested} -> {key, normalize_safe_term!(nested, allow_atoms)} end)
  end

  defp normalize_safe_term!(_value, _allow_atoms) do
    raise ArgumentError, "unsupported value in Pack row safe authority"
  end

  defp finite_number!(value) when is_integer(value), do: value

  defp finite_number!(value) when is_float(value) do
    encoded = :erlang.float_to_binary(value, [:short])

    if String.contains?(encoded, ["nan", "inf"]) do
      raise ArgumentError, "Pack row authority numbers must be finite"
    end

    value
  end

  defp string!(value, _field) when is_binary(value) do
    if String.valid?(value) and
         not Enum.any?(String.to_charlist(value), &(&1 in 0..0x1F and &1 not in [?\n, ?\r, ?\t])) do
      value
    else
      raise ArgumentError, "Pack row strings must be valid UTF-8 without control bytes"
    end
  end

  defp string!(_value, field) do
    raise ArgumentError, "invalid type for Pack row field #{inspect(field)}: expected string"
  end

  defp canonical_child_id!(value, _field) when is_integer(value), do: value

  defp canonical_child_id!(value, field) when is_binary(value),
    do: canonical_string!(value, field)

  defp canonical_child_id!(value, field)
       when is_atom(value) and value not in [nil, true, false] do
    inspected = inspect(value)

    if Regex.match?(@module_string, inspected),
      do: inspected,
      else: canonical_string!(value, field)
  end

  defp canonical_child_id!(value, field) when is_map(value) do
    tuple = normalize_keys!(value, ["tuple"])["tuple"]

    if is_list(tuple) do
      %{"tuple" => Enum.map(tuple, &canonical_child_id!(&1, field))}
    else
      raise ArgumentError, "canonical child tuple projection requires an ordered list"
    end
  end

  defp canonical_child_id!(_value, _field) do
    raise ArgumentError, "invalid canonical child id"
  end

  defp safe_surface_data?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} ->
      not secret_like_key?(key) and safe_surface_data?(nested)
    end)
  end

  defp safe_surface_data?(value) when is_list(value), do: Enum.all?(value, &safe_surface_data?/1)

  defp safe_surface_data?(value) when is_binary(value) do
    downcased = String.downcase(value)

    not String.starts_with?(downcased, ["http://", "https://", "javascript:"]) and
      not String.contains?(downcased, ["<script", "<html", "</"])
  end

  defp safe_surface_data?(_value), do: true

  defp secret_like_key?(key) do
    key
    |> String.downcase()
    |> String.contains?([
      "secret",
      "password",
      "token",
      "api_key",
      "authorization",
      "script",
      "html"
    ])
  end

  defp raw_filesystem_root?(value) do
    String.starts_with?(value, [
      "file://",
      "/Users/",
      "/home/",
      "/tmp/",
      "/var/",
      "/etc/",
      "/opt/",
      "/usr/",
      "/private/",
      "/Volumes/",
      "/Applications/",
      "/Library/"
    ]) or Regex.match?(~r/\A[A-Za-z]:[\\\/]/, value)
  end

  defp module_string!(value, field) when is_atom(value) do
    value
    |> inspect()
    |> module_string!(field)
  end

  defp module_string!(value, _field) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@module_string, value) do
      value
    else
      raise ArgumentError, "Pack row module strings must name an Elixir module"
    end
  end

  defp module_string!(_value, field) do
    raise ArgumentError,
          "invalid type for Pack row payload field #{inspect(field)}: expected module"
  end

  defp canonical_string!(value, field)
       when is_atom(value) and value not in [nil, true, false] do
    value
    |> Atom.to_string()
    |> canonical_string!(field)
  end

  defp canonical_string!(value, _field) when is_binary(value) do
    if canonical_string?(value) do
      value
    else
      raise ArgumentError, "Pack row canonical strings must be non-empty, valid, and trimmed"
    end
  end

  defp canonical_string!(_value, field) do
    raise ArgumentError,
          "invalid type for Pack row payload field #{inspect(field)}: expected string"
  end

  defp canonical_string?(value) do
    value != "" and String.valid?(value) and value == String.trim(value) and
      not Enum.any?(String.to_charlist(value), &(&1 in 0..0x1F or &1 == 0x7F))
  end

  defp confined_path!(value, field) do
    path = canonical_string!(value, field)
    segments = String.split(path, "/", trim: false)

    if path == "." or
         (not String.starts_with?(path, "/") and not String.contains?(path, "\\") and
            Enum.all?(segments, &(&1 not in ["", ".", ".."]))) do
      path
    else
      raise ArgumentError,
            "Pack row path field #{inspect(field)} must be a confined relative path"
    end
  end

  defp sha256!(value, _field) when is_binary(value) do
    if Regex.match?(@sha256, value) do
      value
    else
      raise ArgumentError, "Pack row SHA-256 values must be lowercase hexadecimal"
    end
  end

  defp sha256!(_value, field) do
    raise ArgumentError,
          "invalid type for Pack row payload field #{inspect(field)}: expected SHA-256 string"
  end

  defp verify_reference_digest!(_schema, _payload, _source_authority, nil), do: :ok

  defp verify_reference_digest!(schema, payload, source_authority, digest_field) do
    expected = reference_digest(schema, Map.delete(payload, digest_field), source_authority)

    if payload[digest_field] != expected do
      raise ArgumentError,
            "Pack row #{digest_field} does not match the normalized #{schema} authority"
    end
  end

  defp reference_digest(schema, payload, source_authority) do
    :crypto.hash(
      :sha256,
      "allbert.pack.row.#{schema}.v1\0" <>
        canonical_json!(%{"payload" => payload, "source_authority" => source_authority})
    )
    |> Base.encode16(case: :lower)
  end

  defp validate_row_envelope!(row, %Contribution{owner: owner}) do
    if row.schema_version != 1 do
      raise ArgumentError, "Pack Row schema_version must be 1"
    end

    validate_owner!(owner)

    unless canonical_string?(row.owner_id) and row.owner_id == owner.id do
      raise ArgumentError, "Pack Row owner_id must match Pack Owner id"
    end

    unless is_atom(row.kind) do
      raise ArgumentError, "Pack Row kind must be a callback atom"
    end

    contract = contract_for_callback!(row.kind)
    expected_schema = Map.fetch!(@schema_atoms, contract["payload_schema"])

    if contract["reserved_empty"] or row.payload_schema != expected_schema do
      raise ArgumentError,
            "Pack Row callback #{inspect(row.kind)} requires payload schema #{inspect(expected_schema)}"
    end

    contract
  end

  defp validate_owner!(%Owner{schema_version: 1, kind: kind, id: id, application: application})
       when kind in [:compiled_pack, :legacy_plugin, :declared_pack] and
              (is_nil(application) or
                 (is_atom(application) and application not in [true, false])) do
    unless canonical_string?(id) do
      raise ArgumentError, "Pack Owner id must be canonical"
    end
  end

  defp validate_owner!(_owner) do
    raise ArgumentError, "invalid Pack Owner"
  end

  defp validate_identity!(row, contract, payload) do
    identity = contract["identity"]
    expected_namespace = Map.fetch!(@contract_atoms, identity["namespace"])
    expected_value = payload[identity["field"]]

    case row.identity do
      %{namespace: ^expected_namespace, value: ^expected_value} = value
      when map_size(value) == 2 and is_binary(expected_value) ->
        :ok

      _other ->
        raise ArgumentError, "Pack Row identity does not match its payload schema"
    end
  end

  defp validate_order!(row, contract) do
    order = contract["order"]
    allowed = Enum.map(order["namespaces"], &Map.fetch!(@contract_atoms, &1))

    validate_order_kind!(order["kind"], row, allowed)
  end

  defp validate_order_kind!("numeric", row, allowed),
    do: validate_numeric_order!(row, allowed)

  defp validate_order_kind!("lexical", row, _allowed),
    do: validate_lexical_order!(row)

  defp validate_order_kind!(_kind, _row, _allowed), do: invalid_order!()

  defp validate_numeric_order!(
         %{kind: :actions, order: %{namespace: :alias_target} = order} = row,
         _allowed
       ) do
    {_namespace, value} = numeric_order_pair!(order)
    validate_action_alias_order!(row, value)
  end

  defp validate_numeric_order!(row, allowed) do
    {namespace, _value} = numeric_order_pair!(row.order)

    if namespace in allowed, do: :ok, else: invalid_order!()
  end

  defp numeric_order_pair!(%{namespace: namespace, value: value} = exact)
       when map_size(exact) == 2 and is_integer(value) and value >= 0,
       do: {namespace, value}

  defp numeric_order_pair!(_order), do: invalid_order!()

  defp validate_lexical_order!(row) do
    case row.order do
      %{namespace: :lexical, value: value} = exact
      when map_size(exact) == 2 and is_binary(value) and value == row.identity.value ->
        :ok

      _other ->
        invalid_order!()
    end
  end

  @spec invalid_order!() :: no_return()
  defp invalid_order!,
    do: raise(ArgumentError, "Pack Row order does not match its payload schema")

  defp validate_action_alias_order!(row, value) do
    case row.payload["registry_order"] || row.payload[:registry_order] do
      nil -> :ok
      ^value -> :ok
      _other -> raise ArgumentError, "action alias-target order disagrees with registry_order"
    end
  end

  defp validate_m0_digest!(nil), do: :ok
  defp validate_m0_digest!(value), do: sha256!(value, "m0_payload_sha256")

  defp owner_neutral_source_authority(
         %{"source_authority" => %{"kind" => "none"}},
         nil,
         _contribution
       ),
       do: nil

  defp owner_neutral_source_authority(contract, source_authority, contribution) do
    spec = contract["source_authority"]

    owner_neutralize_fields!(
      spec["fields"],
      source_authority,
      spec["definitions"] || %{},
      contribution
    )
  end

  defp owner_neutralize_fields!(fields, payload, definitions, contribution) do
    Enum.reduce(fields, payload, fn field, authority ->
      name = field["name"]
      value = Map.fetch!(authority, name)

      Map.put(
        authority,
        name,
        owner_neutralize_field!(field, value, definitions, contribution)
      )
    end)
  end

  defp owner_neutralize_field!(field, value, definitions, contribution) do
    case {field["owner_reference"], field["owner_reference_source"]} do
      {"none", nil} ->
        owner_neutralize_nested!(field, value, definitions, contribution)

      {classification, source}
      when classification in ["packaging_owner", "application_reference"] and
             is_binary(source) ->
        owner_neutralize_reference!(field, value, classification, source, contribution)

      invalid ->
        raise ArgumentError,
              "unclassified Pack row owner reference: #{inspect(invalid)}"
    end
  end

  defp owner_neutralize_reference!(field, value, classification, source, contribution) do
    if is_nil(value) and field["nullable"] do
      nil
    else
      owner_neutralize_required_reference!(
        field,
        value,
        classification,
        source,
        contribution
      )
    end
  end

  defp owner_neutralize_required_reference!(
         field,
         value,
         classification,
         source,
         contribution
       ) do
    expected = owner_reference_value!(source, contribution)

    if value == expected do
      @alias_owner
    else
      raise ArgumentError,
            "Pack row #{classification} field #{inspect(field["name"])} does not match #{source}"
    end
  end

  defp owner_neutralize_nested!(_field, nil, _definitions, _contribution), do: nil

  defp owner_neutralize_nested!(
         %{"list_semantics" => semantics, "type" => type},
         values,
         definitions,
         contribution
       )
       when semantics in ["ordered", "set"] and is_list(values) do
    Enum.map(values, &owner_neutralize_type!(type, &1, definitions, contribution))
  end

  defp owner_neutralize_nested!(
         %{"type" => type},
         value,
         definitions,
         contribution
       ) do
    owner_neutralize_type!(type, value, definitions, contribution)
  end

  defp owner_neutralize_type!(type, value, definitions, contribution) do
    case Map.get(definitions, type) do
      %{"kind" => "exact_object", "fields" => fields} ->
        owner_neutralize_fields!(fields, value, definitions, contribution)

      %{"kind" => "variable_map", "value_type" => value_type} ->
        Map.new(value, fn {key, nested} ->
          {key, owner_neutralize_type!(value_type, nested, definitions, contribution)}
        end)

      _scalar_or_unclassified_definition ->
        value
    end
  end

  defp owner_reference_value!("owner.id", %Contribution{owner: owner}), do: owner.id

  defp owner_reference_value!("owner.application", %Contribution{
         owner: %Owner{application: application}
       })
       when is_atom(application) and application not in [nil, true, false],
       do: Atom.to_string(application)

  defp owner_reference_value!("owner.application", _contribution) do
    raise ArgumentError, "Pack Owner application is required by this row schema"
  end

  defp owner_reference_value!("descriptor.provenance.component", %Contribution{
         descriptor: %Descriptor{} = descriptor
       }) do
    case Descriptor.validate(descriptor) do
      {:ok, validated} ->
        validated.provenance.component

      {:error, _reason} ->
        raise ArgumentError,
              "valid Pack descriptor provenance is required by this row schema"
    end
  end

  defp owner_reference_value!("descriptor.provenance.component", _contribution) do
    raise ArgumentError, "Pack descriptor provenance is required by this row schema"
  end

  defp owner_reference_value!(source, _contribution) do
    raise ArgumentError, "unsupported Pack row owner-reference source: #{inspect(source)}"
  end

  defp owner_neutral_authority(contract, payload, contribution) do
    owner_neutralize_fields!(
      contract["fields"],
      payload,
      contract["definitions"] || %{},
      contribution
    )
  end

  defp owner_neutral_identity(row, contract) do
    identity_field = contract["identity"]["field"]
    field_contract = Enum.find(contract["fields"], &(&1["name"] == identity_field))

    value =
      case field_contract["owner_reference"] do
        "none" -> row.identity.value
        _classified -> @alias_owner
      end

    %{"namespace" => Atom.to_string(row.identity.namespace), "value" => value}
  end

  defp owner_neutral_order_value(row, contract) do
    identity_field = contract["identity"]["field"]
    field_contract = Enum.find(contract["fields"], &(&1["name"] == identity_field))

    case {contract["order"]["kind"], field_contract["owner_reference"]} do
      {"lexical", classification} when classification != "none" -> @alias_owner
      _other -> row.order.value
    end
  end

  defp recompute_reference_digest(payload, _schema, _source_authority, nil), do: payload

  defp recompute_reference_digest(payload, schema, source_authority, digest_field) do
    Map.put(
      payload,
      digest_field,
      reference_digest(schema, Map.delete(payload, digest_field), source_authority)
    )
  end

  defp canonical_json!(value) when is_map(value) do
    encoded =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, nested} -> [encode_string!(key), ?:, canonical_json!(nested)] end)
      |> Enum.intersperse(?,)

    IO.iodata_to_binary([?{, encoded, ?}])
  end

  defp canonical_json!(value) when is_list(value) do
    encoded = value |> Enum.map(&canonical_json!/1) |> Enum.intersperse(?,)
    IO.iodata_to_binary([?[, encoded, ?]])
  end

  defp canonical_json!(value) when is_binary(value), do: encode_string!(value)
  defp canonical_json!(value) when is_integer(value), do: Integer.to_string(value)

  defp canonical_json!(value) when is_float(value) do
    finite_number!(value)
    :erlang.float_to_binary(value, [:short])
  end

  defp canonical_json!(true), do: "true"
  defp canonical_json!(false), do: "false"
  defp canonical_json!(nil), do: "null"

  defp encode_string!(value) do
    escaped = value |> String.to_charlist() |> Enum.map(&escape_codepoint/1)
    IO.iodata_to_binary([?\", escaped, ?\"])
  end

  defp escape_codepoint(?\"), do: "\\\""
  defp escape_codepoint(?\\), do: "\\\\"
  defp escape_codepoint(?\b), do: "\\b"
  defp escape_codepoint(?\f), do: "\\f"
  defp escape_codepoint(?\n), do: "\\n"
  defp escape_codepoint(?\r), do: "\\r"
  defp escape_codepoint(?\t), do: "\\t"

  defp escape_codepoint(codepoint) when codepoint in 0..0x1F do
    "\\u" <> (codepoint |> Integer.to_string(16) |> String.pad_leading(4, "0"))
  end

  defp escape_codepoint(codepoint), do: <<codepoint::utf8>>
end
