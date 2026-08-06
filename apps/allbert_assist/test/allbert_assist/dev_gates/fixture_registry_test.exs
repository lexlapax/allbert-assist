defmodule AllbertAssist.DevGates.FixtureRegistryTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.DevGates.FixtureRegistry

  test "shipped registry has unique ids, unique real paths, and valid owner CWDs" do
    root = Path.expand("../../../../..", __DIR__)
    core = Path.join(root, "apps/allbert_assist")

    assert :ok = FixtureRegistry.validate!(root, fn :core -> core end)

    assert Enum.map(FixtureRegistry.entries(), & &1.id) == [
             "memory_projection_and_schema_floor",
             "security_projection_principal_and_inventory"
           ]
  end

  test "duplicate coverage and missing paths fail before a sentinel runs" do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-fixture-registry-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    entries = [
      %{
        id: "one",
        owner: :core,
        tag: :duplicate,
        expected_tests: 0,
        paths: ["missing.exs"]
      },
      %{
        id: "one",
        owner: :core,
        tag: :duplicate,
        expected_tests: 0,
        paths: ["missing.exs"]
      }
    ]

    error =
      assert_raise Mix.Error, fn ->
        FixtureRegistry.validate_entries!(entries, root, fn :core -> root end)
      end

    assert error.message =~ "duplicate fixture sentinel id: one"
    assert error.message =~ "duplicate fixture sentinel path: missing.exs"
    assert error.message =~ "duplicate fixture sentinel tag: duplicate"
    assert error.message =~ "expected_tests must be a positive integer"
    assert error.message =~ "path missing: missing.exs"
  end

  test "unknown sentinel fails closed" do
    assert_raise Mix.Error, "unknown fixture sentinel absent", fn ->
      FixtureRegistry.fetch!("absent")
    end
  end
end
