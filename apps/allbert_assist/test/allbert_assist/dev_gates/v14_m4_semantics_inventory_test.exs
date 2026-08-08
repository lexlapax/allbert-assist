defmodule AllbertAssist.DevGates.V14M4SemanticsInventoryTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.DevGates.V14M4SemanticsInventory

  @fixture Path.expand("../../fixtures/v1.4/m4_semantics_inventory.json", __DIR__)

  test "the M4 ledger owns every truthy and JSON-safe definition and use-site" do
    snapshot = V14M4SemanticsInventory.snapshot()

    assert snapshot["schema_version"] == 1
    assert snapshot["normalization"] == "v14_m4_semantics_inventory_v1"

    assert snapshot["counts"] == %{
             "definitions" => 39,
             "json_safe" => 13,
             "truthy" => 26,
             "use_sites" => 63
           }

    assert Enum.all?(snapshot["definitions"], fn definition ->
             definition["definition_sha256"] =~ ~r/^[0-9a-f]{64}$/ and
               definition["profile"] != "" and
               definition["purpose"] != "" and
               definition["trust_or_wire"] != "" and
               definition["disposition"] in ["retain_local", "named_equivalence"] and
               definition["use_sites"] != []
           end)

    assert Enum.all?(snapshot["definitions"], fn definition ->
             Enum.all?(definition["use_sites"], fn use_site ->
               use_site["caller"] =~ ~r/^[a-zA-Z0-9_?!]+\/\d+$/ and
                 use_site["call_count"] + use_site["capture_count"] > 0 and
                 use_site["purpose"] != "" and
                 use_site["trust_or_wire"] != ""
             end)
           end)
  end

  test "the repository-owned fixture is valid and matches production source" do
    assert V14M4SemanticsInventory.fixture_path() == @fixture
    assert :ok = V14M4SemanticsInventory.check!()
  end

  test "source fingerprints ignore line movement but detect semantic drift" do
    source = """
    defmodule Example do
      def enabled?(value), do: truthy?(value)
      defp truthy?(value), do: value in [true, "true"]
    end
    """

    moved = String.replace(source, "  def enabled?", "\n\n  def enabled?")
    changed = String.replace(source, ~s([true, "true"]), ~s([true, "true", "1"]))

    assert V14M4SemanticsInventory.discover_source(source, "example.ex") ==
             V14M4SemanticsInventory.discover_source(moved, "example.ex")

    refute V14M4SemanticsInventory.discover_source(source, "example.ex") ==
             V14M4SemanticsInventory.discover_source(changed, "example.ex")
  end
end
