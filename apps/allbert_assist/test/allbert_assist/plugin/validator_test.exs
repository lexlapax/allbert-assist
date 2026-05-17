defmodule AllbertAssist.Plugin.ValidatorTest do
  use ExUnit.Case, async: false

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
        %{channel_id: "duplicate"},
        %{channel_id: "duplicate"}
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
