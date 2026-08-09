defmodule AllbertAssist.Actions.SnapshotCatalogTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Actions.{Capability, SnapshotCatalog}
  alias AllbertAssist.Pack.ActionBinding
  alias AllbertAssist.Pack.Registry.Snapshot

  # Capability metadata reads `name/0` off the projected module, so a binding
  # needs a module that answers it. This row asserts how SnapshotCatalog
  # projects bindings, not anything about a particular action, so it answers
  # for itself rather than reaching for a shipped action module.
  def name, do: "direct_answer"

  test "authoritative bindings drive ordered public action views" do
    snapshot = snapshot([binding(__MODULE__, 1, :agent)])

    assert SnapshotCatalog.modules(snapshot) == [__MODULE__]
    assert SnapshotCatalog.agent_modules(snapshot) == [__MODULE__]
    assert SnapshotCatalog.internal_modules(snapshot) == []
    assert SnapshotCatalog.names(snapshot) == ["direct_answer"]

    assert {:ok, __MODULE__} = SnapshotCatalog.resolve(snapshot, "Direct Answer")

    assert {:ok, %Capability{name: "direct_answer", exposure: :agent}} =
             SnapshotCatalog.capability(snapshot, :direct_answer)
  end

  test "shadow or malformed snapshots fail closed" do
    shadow = %{snapshot([]) | publication: :shadow}

    assert SnapshotCatalog.modules(shadow) == []
    assert SnapshotCatalog.modules(:invalid) == []

    assert {:error, {:unknown_action, "direct_answer"}} =
             SnapshotCatalog.resolve(shadow, "direct_answer")
  end

  defp snapshot(bindings) do
    %Snapshot{
      schema_version: 1,
      publication: :authoritative,
      behavior_digest: String.duplicate("a", 64),
      contributions: [],
      effective_actions: bindings,
      compatibility_aliases: [],
      compatibility_diagnostics: []
    }
  end

  defp binding(module, order, exposure) do
    %ActionBinding{
      schema_version: 1,
      module: module,
      name: module.name(),
      source_lane: :native_static,
      legacy_index: order,
      registry_order: order,
      normalized_capability: %{
        app_id: nil,
        confirmation: :not_required,
        execution_mode: :read_only,
        exposure: exposure,
        notes: nil,
        permission: :read_only,
        plugin_id: nil,
        resumable?: false,
        retry_safety: :unsafe,
        skill_backed?: true
      },
      m0_row_sha256: String.duplicate("b", 64),
      input_schema_sha256: String.duplicate("c", 64),
      output_schema_sha256: String.duplicate("d", 64)
    }
  end
end
