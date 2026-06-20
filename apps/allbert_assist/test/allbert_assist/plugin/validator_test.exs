defmodule AllbertAssist.Plugin.ValidatorTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.Plugin.Entry
  alias AllbertAssist.Plugin.Manifest
  alias AllbertAssist.Plugin.Validator

  defmodule ValidPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.valid"

    @impl true
    def display_name, do: "Example Valid"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok
  end

  defmodule InvalidIdPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "Bad.Plugin"

    @impl true
    def display_name, do: "Bad Id"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok
  end

  defmodule MissingValidatePlugin do
    def plugin_id, do: "example.missing_validate"
    def display_name, do: "Missing Validate"
    def version, do: "0.1.0"
  end

  defmodule DuplicateContributionsPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.duplicates"

    @impl true
    def display_name, do: "Example Duplicates"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def skill_paths, do: ["/tmp/example", "/tmp/example"]

    @impl true
    def channels do
      [
        %{
          channel_id: "duplicate",
          primitives: [:list],
          threading: :flat,
          trust_class: :server_readable
        },
        %{
          channel_id: "duplicate",
          primitives: [:list],
          threading: :flat,
          trust_class: :server_readable
        }
      ]
    end
  end

  defmodule MissingPrimitivesChannelPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.missing_primitives"

    @impl true
    def display_name, do: "Missing Primitives"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels,
      do: [%{channel_id: "missing_primitives", threading: :flat, trust_class: :server_readable}]
  end

  defmodule InvalidPrimitiveChannelPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.invalid_primitive"

    @impl true
    def display_name, do: "Invalid Primitive"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels,
      do: [
        %{
          channel_id: "invalid_primitive",
          primitives: [:button],
          threading: :flat,
          trust_class: :server_readable
        }
      ]
  end

  defmodule UnknownPrimitiveChannelPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.unknown_primitive"

    @impl true
    def display_name, do: "Unknown Primitive"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels,
      do: [
        %{
          channel_id: "unknown_primitive",
          primitives: [:list, :magic],
          threading: :flat,
          trust_class: :server_readable
        }
      ]
  end

  defmodule InvalidThreadingChannelPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.invalid_threading"

    @impl true
    def display_name, do: "Invalid Threading"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels,
      do: [
        %{
          channel_id: "invalid_threading",
          primitives: [:list],
          threading: :magic,
          trust_class: :server_readable
        }
      ]
  end

  defmodule MissingTrustClassChannelPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.missing_trust_class"

    @impl true
    def display_name, do: "Missing Trust Class"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels,
      do: [%{channel_id: "missing_trust_class", primitives: [:list], threading: :flat}]
  end

  defmodule InvalidTrustClassChannelPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.invalid_trust_class"

    @impl true
    def display_name, do: "Invalid Trust Class"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels,
      do: [
        %{
          channel_id: "invalid_trust_class",
          primitives: [:list],
          threading: :flat,
          trust_class: :mystery
        }
      ]
  end

  defmodule InvalidReplyKeyTypeChannelPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.invalid_reply_key_type"

    @impl true
    def display_name, do: "Invalid Reply Key Type"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels,
      do: [
        %{
          channel_id: "invalid_reply_key_type",
          primitives: [:list],
          threading: :reply_chain,
          trust_class: :server_readable,
          reply_key_type: :phone_number
        }
      ]
  end

  defmodule InvalidQuoteTtlChannelPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.invalid_quote_ttl"

    @impl true
    def display_name, do: "Invalid Quote TTL"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels,
      do: [
        %{
          channel_id: "invalid_quote_ttl",
          primitives: [:list],
          threading: :reply_chain,
          trust_class: :server_readable,
          reply_key_type: :opaque_id,
          quote_ttl_ms: 0
        }
      ]
  end

  defmodule ReleaseAvailabilityPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.release_availability"

    @impl true
    def display_name, do: "Release Availability"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels do
      [
        %{
          channel_id: "example_release_channel",
          primitives: [:list],
          threading: :flat,
          trust_class: :server_readable
        }
      ]
    end

    @impl true
    def release_availability do
      [
        %{
          kind: :channel,
          id: "example_release_channel",
          release_status: :implemented_not_released,
          live_use_allowed?: false,
          decision: "Implemented, but not released for live use.",
          decision_ref: "docs/plans/example.md",
          future_features_ref: "docs/plans/future-features.md"
        }
      ]
    end
  end

  defmodule InvalidReleaseAvailabilityPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.invalid_release_availability"

    @impl true
    def display_name, do: "Invalid Release Availability"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def release_availability, do: [%{kind: :channel, id: "missing_status"}]
  end

  defmodule YamlReleaseAvailabilityPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.yaml_release_availability"

    @impl true
    def display_name, do: "YAML Release Availability"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels do
      [
        %{
          channel_id: "yaml_release_channel",
          primitives: [:list],
          threading: :flat,
          trust_class: :server_readable
        }
      ]
    end
  end

  defmodule CrossOwnedReleaseAvailabilityPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "example.cross_owned_release_availability"

    @impl true
    def display_name, do: "Cross-Owned Release Availability"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels do
      [
        %{
          channel_id: "owned_channel",
          primitives: [:list],
          threading: :flat,
          trust_class: :server_readable
        }
      ]
    end

    @impl true
    def release_availability do
      [
        %{
          kind: :channel,
          id: "other_channel",
          release_status: :implemented_not_released,
          live_use_allowed?: false,
          decision: "This plugin must not be able to block another channel.",
          decision_ref: "docs/plans/example.md"
        }
      ]
    end
  end

  test "validates plugin modules into normalized entries without atomizing ids" do
    before_count = :erlang.system_info(:atom_count)

    assert {:ok, %Entry{} = entry} =
             Validator.validate_module(ValidPlugin, source: :shipped, root_path: "/tmp/plugin")

    after_count = :erlang.system_info(:atom_count)

    assert entry.plugin_id == "example.valid"
    assert entry.kind == "mixed"
    assert entry.source == :shipped
    assert entry.status == :enabled
    assert entry.trust_status == :trusted
    assert entry.module == ValidPlugin
    assert entry.root_path == "/tmp/plugin"
    assert entry.release_availability == []
    assert after_count == before_count
  end

  test "rejects invalid plugin ids" do
    assert {:error, :invalid_plugin, diagnostics} = Validator.validate_module(InvalidIdPlugin)
    assert Enum.any?(diagnostics, &(&1.kind == :invalid_plugin_id))
  end

  test "requires core callbacks" do
    assert {:error, {:missing_callbacks, callbacks}, diagnostics} =
             Validator.validate_module(MissingValidatePlugin)

    assert {:validate, 1} in callbacks
    assert Enum.any?(diagnostics, &(&1.kind == :missing_callbacks))
  end

  test "records duplicate contribution diagnostics without failing" do
    assert {:ok, entry} = Validator.validate_module(DuplicateContributionsPlugin)

    assert Enum.any?(entry.diagnostics, &(&1.kind == :duplicate_channel_id))
    assert Enum.any?(entry.diagnostics, &(&1.kind == :duplicate_skill_path))
  end

  test "rejects channel descriptors missing primitives" do
    assert {:error, :invalid_plugin, diagnostics} =
             Validator.validate_module(MissingPrimitivesChannelPlugin)

    assert Enum.any?(diagnostics, &(&1.kind == :missing_channel_primitives))
  end

  test "rejects channel primitive declarations without list fallback" do
    assert {:error, :invalid_plugin, diagnostics} =
             Validator.validate_module(InvalidPrimitiveChannelPlugin)

    assert Enum.any?(diagnostics, &(&1.kind == :missing_channel_list_primitive))
  end

  test "rejects unknown channel primitive declarations" do
    assert {:error, :invalid_plugin, diagnostics} =
             Validator.validate_module(UnknownPrimitiveChannelPlugin)

    assert Enum.any?(diagnostics, &(&1.kind == :invalid_channel_primitive))
  end

  test "rejects channel descriptors with invalid threading" do
    assert {:error, :invalid_plugin, diagnostics} =
             Validator.validate_module(InvalidThreadingChannelPlugin)

    assert Enum.any?(diagnostics, &(&1.kind == :invalid_channel_threading))
  end

  test "rejects channel descriptors missing trust_class" do
    assert {:error, :invalid_plugin, diagnostics} =
             Validator.validate_module(MissingTrustClassChannelPlugin)

    assert Enum.any?(diagnostics, &(&1.kind == :missing_channel_trust_class))
  end

  test "rejects channel descriptors with invalid trust_class" do
    assert {:error, :invalid_plugin, diagnostics} =
             Validator.validate_module(InvalidTrustClassChannelPlugin)

    assert Enum.any?(diagnostics, &(&1.kind == :invalid_channel_trust_class))
  end

  test "rejects channel descriptors with invalid reply_key_type" do
    assert {:error, :invalid_plugin, diagnostics} =
             Validator.validate_module(InvalidReplyKeyTypeChannelPlugin)

    assert Enum.any?(diagnostics, &(&1.kind == :invalid_channel_reply_key_type))
  end

  test "rejects channel descriptors with invalid quote_ttl_ms" do
    assert {:error, :invalid_plugin, diagnostics} =
             Validator.validate_module(InvalidQuoteTtlChannelPlugin)

    assert Enum.any?(diagnostics, &(&1.kind == :invalid_channel_quote_ttl_ms))
  end

  test "normalizes plugin release availability declarations" do
    assert {:ok, entry} = Validator.validate_module(ReleaseAvailabilityPlugin)

    assert [
             %{
               kind: :channel,
               id: "example_release_channel",
               release_status: :implemented_not_released,
               live_use_allowed?: false
             }
           ] = entry.release_availability
  end

  test "loads plugin-owned release availability YAML" do
    root = Path.join(System.tmp_dir!(), "plugin-validator-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([root, "priv", "allbert"]))

    File.write!(Path.join([root, "priv", "allbert", "release_availability.yaml"]), """
    declarations:
      - kind: channel
        id: yaml_release_channel
        release_status: implemented_not_released
        live_use_allowed: false
        decision: "Implemented, but not released for live use."
        decision_ref: docs/plans/example.md
    """)

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, entry} =
             Validator.validate_module(YamlReleaseAvailabilityPlugin, root_path: root)

    assert [
             %{
               kind: :channel,
               id: "yaml_release_channel",
               release_status: :implemented_not_released,
               live_use_allowed?: false
             }
           ] = entry.release_availability
  end

  test "rejects release declarations for capabilities not owned by the plugin" do
    assert {:error, :invalid_plugin, diagnostics} =
             Validator.validate_module(CrossOwnedReleaseAvailabilityPlugin)

    assert Enum.any?(diagnostics, &(&1.kind == :release_availability_not_owned))
  end

  test "rejects invalid plugin release availability declarations" do
    assert {:error, :invalid_plugin, diagnostics} =
             Validator.validate_module(InvalidReleaseAvailabilityPlugin)

    assert Enum.any?(diagnostics, &(&1.kind == :invalid_release_availability))
  end

  test "normalizes valid skill-only manifests" do
    root = Path.join(System.tmp_dir!(), "plugin-validator-#{System.unique_integer([:positive])}")
    skills_root = Path.join(root, "skills")
    File.mkdir_p!(skills_root)
    manifest_path = Path.join(root, "allbert_plugin.json")

    File.write!(manifest_path, """
    {
      "schema_version": 1,
      "plugin_id": "example.skills",
      "name": "Example Skills",
      "version": "0.1.0",
      "kind": "skills",
      "skill_paths": ["skills"]
    }
    """)

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, entry} = Manifest.read(manifest_path, source: :home)
    assert entry.plugin_id == "example.skills"
    assert entry.source == :home
    assert entry.trust_status == :pending
    assert entry.skill_paths == [Path.expand(skills_root)]
  end

  test "rejects path traversal and code-bearing home manifests" do
    root = Path.join(System.tmp_dir!(), "plugin-validator-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    manifest_path = Path.join(root, "allbert_plugin.json")

    File.write!(manifest_path, """
    {
      "schema_version": 1,
      "plugin_id": "example.bad",
      "name": "Example Bad",
      "version": "0.1.0",
      "kind": "skills",
      "module": "Example.Bad",
      "skill_paths": ["../escape"]
    }
    """)

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, :rejected, diagnostics} = Manifest.read(manifest_path, source: :home)
    assert Enum.any?(diagnostics, &(&1.kind == :code_bearing_home_plugin))
    assert Enum.any?(diagnostics, &(&1.kind == :invalid_skill_path))
  end
end
