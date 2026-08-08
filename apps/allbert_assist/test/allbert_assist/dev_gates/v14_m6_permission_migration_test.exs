defmodule AllbertAssist.DevGates.V14M6PermissionMigrationTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.DevGates.V14M6PermissionMigration

  test "the frozen predecessor roster is complete and self-validating" do
    fixture = V14M6PermissionMigration.load_fixture!()

    assert fixture["provenance"]["source_sha"] ==
             "7ae566f59f74cb51d8aed77e2f51c3df80172e1f"

    assert fixture["counts"] == %{
             "allowed" => 168,
             "authorize" => 295,
             "calls" => 648,
             "files" => 218,
             "permission_call_files" => 217,
             "response_status" => 182,
             "vocabulary" => 3
           }

    assert fixture["non_action_families"] |> Map.keys() |> Enum.sort() == [
             "allbert_browser_helper",
             "allbert_notes_files_helper",
             "coding_bash_spec",
             "coding_session_guard",
             "intent_agent",
             "plan_build",
             "resource_grants",
             "stocksage_helper"
           ]
  end

  test "current production callers are the one-for-one approved migration" do
    assert :ok = V14M6PermissionMigration.check!()
  end

  test "call identity ignores line movement but binds context, order, and arguments" do
    predecessor = """
    defmodule Example do
      alias AllbertAssist.Security.PermissionGate, as: Gate

      def run(permission, context) do
        decision = Gate.authorize(permission, context)
        Gate.allowed?(decision)
        Gate.response_status(decision)
      end
    end
    """

    moved = String.replace(predecessor, "  def run", "\n\n  def run")

    changed =
      String.replace(
        predecessor,
        "Gate.authorize(permission, context)",
        "Gate.authorize(:different_permission, context)"
      )

    assert V14M6PermissionMigration.discover_predecessor_source(predecessor, "example.ex") ==
             V14M6PermissionMigration.discover_predecessor_source(moved, "example.ex")

    refute V14M6PermissionMigration.discover_predecessor_source(predecessor, "example.ex") ==
             V14M6PermissionMigration.discover_predecessor_source(changed, "example.ex")
  end

  test "current discovery accepts only the approved owner targets" do
    source = """
    defmodule Example do
      alias AllbertAssist.{Security, Runtime.Response}
      alias AllbertAssist.Security.Policy, as: SecurityPolicy

      def run(permission, context) do
        decision = Security.authorize(permission, context)
        Security.allowed?(decision)
        Response.permission_status(decision)
        SecurityPolicy.coding_tier(context)
      end
    end
    """

    assert V14M6PermissionMigration.discover_current_source(source, "example.ex")
           |> Enum.map(&{&1["role"], &1["target"]}) == [
             {"authorize", "AllbertAssist.Security.authorize/2"},
             {"allowed", "AllbertAssist.Security.allowed?/1"},
             {"response_status", "AllbertAssist.Runtime.Response.permission_status/1"},
             {"coding_tier", "AllbertAssist.Security.Policy.coding_tier/1"}
           ]
  end
end
